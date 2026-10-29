//  Shared fakes, fixtures and helpers. The scripted API, transfers and
//  connectivity come from CloudConvertKitTesting.
//

import Foundation
import XCTest
import Network
@testable import CloudConvertKit
@_exported import CloudConvertKitTesting
import CloudConvertKitUI

// MARK: - Fakes

// The fakes live in CloudConvertKitTesting; the tests keep their old names.
typealias FakeAPI = FakeCloudConvertAPI

typealias FakeTransfers = FakeFileTransfers

/// Online when work starts, then the network drops: requests fail through
/// the API's scripted errors, and every wait for the network times out
/// until the test sets `isBack`.

final class DroppedNetwork: ConnectivityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var back = false

    var isBack: Bool {
        get { lock.lock(); defer { lock.unlock() }; return back }
        set { lock.lock(); back = newValue; lock.unlock() }
    }

    var isConnected: Bool { get async { true } }
    var isExpensive: Bool { get async { false } }
    func waitUntilConnected(timeout: TimeInterval) async throws {
        guard isBack else { throw CloudConvertError.notConnected }
    }
    func changes() -> AsyncStream<Bool> { AsyncStream { $0.yield(true); $0.finish() } }
}

/// Fails uploads and/or downloads with `.notConnected` until the network is back.
final class OfflineUntilBackTransfers: FileTransferring, @unchecked Sendable {
    let inner: FakeTransfers
    let network: DroppedNetwork
    let failUploads: Bool
    let failDownloads: Bool

    init(inner: FakeTransfers, network: DroppedNetwork, failUploads: Bool, failDownloads: Bool) {
        self.inner = inner; self.network = network; self.failUploads = failUploads; self.failDownloads = failDownloads
    }

    func upload(id: String, request: URLRequest, bodyFile: URL,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        if failUploads, !network.isBack { throw CloudConvertError.notConnected }
        return try await inner.upload(id: id, request: request, bodyFile: bodyFile, progress: progress)
    }

    func download(id: String, request: URLRequest, destination: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        if failDownloads, !network.isBack { throw CloudConvertError.notConnected }
        return try await inner.download(id: id, request: request, destination: destination, progress: progress)
    }

    func awaitExistingTransfer(id: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        try await inner.awaitExistingTransfer(id: id, progress: progress)
    }

    func cancel(id: String) { inner.cancel(id: id) }
    func forget(id: String) { inner.forget(id: id) }
}

/// The engine's record store, with `all()` held while `hold()` is in effect.
final class HeldStore: ConversionRecordStoring, @unchecked Sendable {
    private let inner: ConversionRecordStore
    private let gate = Gate()
    private let holding = Flag(), held = Flag()

    init(directory: URL) { inner = ConversionRecordStore(directory: directory, logger: SilentCloudConvertLogger()) }

    func hold() { holding.set() }
    func release() { gate.open() }
    /// Whether a call to `all()` is waiting for `release()`.
    var isHolding: Bool { held.isSet }

    func save(_ record: ConversionRecord) async { await inner.save(record) }
    func load(id: String) async -> ConversionRecord? { await inner.load(id: id) }
    func delete(id: String) async { await inner.delete(id: id) }
    func all() async -> [ConversionRecord] {
        if holding.isSet {
            held.set()
            try? await gate.wait()
        }
        return await inner.all()
    }
}

/// A store whose list still shows records that are gone.
final class StaleListStore: ConversionRecordStoring, @unchecked Sendable {
    private let listed: [ConversionRecord]
    init(listed: [ConversionRecord]) { self.listed = listed }
    func save(_ record: ConversionRecord) async {}
    func load(id: String) async -> ConversionRecord? { nil }
    func delete(id: String) async {}
    func all() async -> [ConversionRecord] { listed }
}

/// Serves `POST /jobs`, `GET /jobs/{id}` and `DELETE /jobs/{id}` so the real
/// `CloudConvertAPI` (auth, retries, decoding, error mapping) is exercised.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    /// Body returned by every `GET /jobs/{id}`, with the fixture's id replaced.
    var jobBody: Data = Data()
    var jobStatus = 200
    /// The first this many `GET`s are answered 401.
    var unauthorizedGets = 0
    private(set) var authorizations: [String?] = []
    private(set) var userAgents: [String?] = []
    /// Awaited while `POST /jobs` is in flight, after the server created the job.
    /// Throwing models URLSession: a cancelled request fails client-side,
    /// although the server has already created the job.
    var createHook: (@Sendable (_ jobID: String) async throws -> Void)?
    private(set) var creates: [String] = []
    private(set) var polls = 0
    private(set) var deletes: [String] = []

    var deletesSnapshot: [String] { lock.lock(); defer { lock.unlock() }; return deletes }
    var createsSnapshot: [String] { lock.lock(); defer { lock.unlock() }; return creates }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let path = request.url?.path ?? ""
        lock.withLock {
            authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
            userAgents.append(request.value(forHTTPHeaderField: "User-Agent"))
        }
        switch request.httpMethod {
        case "POST" where path.hasSuffix("/jobs"):
            lock.lock()
            let id = "job-\(creates.count + 1)"
            creates.append(id)
            let hook = createHook
            lock.unlock()
            if let hook { try await hook(id) }
            return HTTPResponse(status: 201, headers: [:], body: Fixtures.createdJob(id: id))
        case "GET":
            lock.lock()
            polls += 1
            let refused = unauthorizedGets > 0
            if refused { unauthorizedGets -= 1 }
            let body = jobBody, status = jobStatus
            lock.unlock()
            if refused { return HTTPResponse(status: 401, headers: [:], body: Data(#"{"message":"Unauthenticated."}"#.utf8)) }
            return HTTPResponse(status: status, headers: [:], body: body)
        case "DELETE":
            lock.lock(); deletes.append(String(path.split(separator: "/").last ?? "")); lock.unlock()
            return HTTPResponse(status: 204, headers: [:], body: Data())
        default:
            return HTTPResponse(status: 404, headers: [:], body: Data())
        }
    }
}

// MARK: - Recorders and synchronisation

/// Thread-safe collector for progress stages (progress handlers are `@Sendable`).
final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [ConversionProgress.Stage] = []

    func append(_ stage: ConversionProgress.Stage) {
        lock.lock(); stages.append(stage); lock.unlock()
    }

    var snapshot: [ConversionProgress.Stage] {
        lock.lock(); defer { lock.unlock() }
        return stages
    }
}

/// Keeps every log line, to check what reaches messages and metadata.
final class LogRecorder: CloudConvertLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(message: String, metadata: [String: String])] = []

    func log(_ level: LogLevel, _ message: @autoclosure () -> String, metadata: [String: String]) {
        let line = (message(), metadata)
        lock.lock(); lines.append(line); lock.unlock()
    }

    var messages: [String] { lock.lock(); defer { lock.unlock() }; return lines.map(\.message) }
    var metadataValues: [String] { lock.lock(); defer { lock.unlock() }; return lines.flatMap { $0.metadata.values } }
}

/// A logger that takes a while to write the line `stop` writes after
/// reporting `.failed` for a kept conversion (a file, analytics…).
final class SlowKeepLogger: CloudConvertLogging, @unchecked Sendable {
    func log(_ level: LogLevel, _ message: @autoclosure () -> String, metadata: [String: String]) {
        if message().contains("to resume") { Thread.sleep(forTimeInterval: 0.5) }
    }
}

/// An async latch: `wait()` suspends until `open()` is called. Like a
/// URLSession request, a waiter whose task is cancelled throws
/// `CancellationError` instead of hanging, so a test of code that does not
/// shield its request fails instead of deadlocking.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = Array(waiters.values)
        waiters = [:]
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class HandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConversionHandle?
    var handle: ConversionHandle? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

// MARK: - Files, fixtures and configuration

enum TestFiles {
    static func temporaryDirectory(_ name: String = UUID().uuidString) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudConvertKitTests-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeFile(named name: String, bytes: Int = 1024, in directory: URL = temporaryDirectory()) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }
}

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func job(_ name: String) throws -> CCJob {
        try CCDateDecoding.makeDecoder().decode(CCDataEnvelope<CCJob>.self, from: data(name)).data
    }

    /// The `POST /jobs` response for a job shaped like the fixtures
    /// (`import` → `convert` → `export`), with a fresh upload form.
    static func createdJob(id: String) -> Data {
        let expires = Int(Date().timeIntervalSince1970) + 3600
        return Data("""
        {"data":{"id":"\(id)","tag":"example-app","status":"waiting","created_at":"2026-09-29T15:51:19+00:00",
          "tasks":[
            {"id":"t-export","name":"export","job_id":"\(id)","status":"waiting","code":null,"message":null,"percent":0,
             "operation":"export/url","result":null,"credits":null},
            {"id":"t-convert","name":"convert","job_id":"\(id)","status":"waiting","code":null,"message":null,"percent":0,
             "operation":"convert","engine":null,"result":null,"credits":null},
            {"id":"t-import","name":"import","job_id":"\(id)","status":"waiting","code":null,"message":null,"percent":0,
             "operation":"import/upload","credits":null,
             "result":{"form":{"url":"https://upload.cloudconvert.com/x/","parameters":{"expires":\(expires),"max_file_count":1,"max_file_size":10000000000,"signature":"sig"}}}}]}}
        """.utf8)
    }
}

extension CloudConvertConfiguration {
    static func testing(workingDirectory: URL = TestFiles.temporaryDirectory("work"),
                        outputDirectory: URL = TestFiles.temporaryDirectory("out")) -> CloudConvertConfiguration {
        var configuration = CloudConvertConfiguration(environment: .sandbox,
                                                      authorizationProvider: NoAuthorization(),
                                                      backgroundSessionIdentifier: "tests.\(UUID().uuidString)",
                                                      workingDirectory: workingDirectory,
                                                      outputDirectory: outputDirectory,
                                                      logger: SilentCloudConvertLogger())
        configuration.jobRetryPolicy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        configuration.uploadRetryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        configuration.downloadRetryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        configuration.apiRetryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02, jitter: 0)
        configuration.polling = PollingPolicy(initialInterval: 0.01, maxInterval: 0.02, multiplier: 1.5, jobTimeout: 5, maxConsecutiveFailures: 3)
        configuration.diskSpaceSafetyMargin = 0
        return configuration
    }
}

/// A conversion a previous launch left behind: its input staged and its job
/// (`jobID`) created, saved where the engine finds pending records.
@discardableResult
func seedPreviousLaunch(id: String = "previous",
                        phase: ConversionPhase,
                        jobID: String = "job-9",
                        configuration: CloudConvertConfiguration,
                        api: FakeAPI,
                        change: (inout ConversionRecord) -> Void = { _ in }) async throws -> ConversionRecord {
    let url = try TestFiles.makeFile(named: "book.epub")
    let specification = try ConversionRequest.convert(url, to: "mobi").makeJobSpecification(defaultTag: nil, defaultTimeout: nil)
    let storage = FileStorage(workingDirectory: configuration.workingDirectory, outputDirectory: configuration.outputDirectory,
                              diskSpaceSafetyMargin: 0)
    let staged = try storage.stage(InputFile(url: url), conversionID: id, limit: .max)
    var record = ConversionRecord(id: id,
                                  specification: specification,
                                  staged: ["import-1": staged],
                                  output: .default,
                                  userInfo: [:],
                                  createdAt: Date().addingTimeInterval(-60),
                                  updatedAt: Date(),
                                  phase: phase,
                                  jobAttempt: 1,
                                  jobID: jobID,
                                  uploadTransfers: [:],
                                  uploadedTaskNames: phase == .uploading ? [] : ["import-1"],
                                  downloadTransfers: [:],
                                  exportedFiles: [])
    change(&record)
    await ConversionRecordStore(directory: storage.recordsDirectory, logger: SilentCloudConvertLogger()).save(record)
    api.seededSpecification = specification
    return record
}

// MARK: - Helpers

/// Polls `condition` until it holds or `timeout` elapses.
func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
}

func outcome(_ status: Int) -> TransferOutcome {
    TransferOutcome(status: status, responseBody: nil, fileURL: nil, errorDescription: nil, urlErrorCode: nil, finishedAt: Date())
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, _ message: @autoclosure () -> String = "",
                       file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, message(), file: file, line: line)
}

/// `nil` when `body` does not finish within `seconds`.
func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await body() }
        group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

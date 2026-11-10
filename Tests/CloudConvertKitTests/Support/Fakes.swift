//  Fakes the tests add to CloudConvertKitTesting's: a network that drops,
//  transfers that fail until it is back, record stores, a scripted HTTP
//  transport for the real API client, and loggers.
//

import Foundation
import XCTest
import Network
@testable import CloudConvertKit
@_exported import CloudConvertKitTesting

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
    let inner: FakeFileTransfers
    let network: DroppedNetwork
    let failUploads: Bool
    let failDownloads: Bool

    init(inner: FakeFileTransfers, network: DroppedNetwork, failUploads: Bool, failDownloads: Bool) {
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

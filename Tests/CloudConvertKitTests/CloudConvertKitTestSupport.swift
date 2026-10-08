//  In-memory fakes for the API client, the transfer layer and connectivity so
//  the engine's orchestration (retries, resume, cancellation, naming) can be
//  tested without a network.
//

import Foundation
import XCTest
@testable import CloudConvertKit

// MARK: - Fake API

/// Scripted API: each call to `getJob` returns the next status in `statuses`.
final class FakeAPI: CloudConvertAPIClient, @unchecked Sendable {

    struct ScriptedTask {
        var name: String
        var operation: String
        var status: CCStatus
        var code: String? = nil
        var message: String? = nil
        var form: (url: String, params: [String: String])? = nil
        var files: [(filename: String, size: Int64?, url: String)] = []
    }

    private let lock = NSLock()
    var createJobError: CloudConvertError?
    var createdSpecifications: [JobSpecification] = []
    /// Specification used by `getJob` when no job was created in this run
    /// (simulates a job that exists on the server from a previous launch).
    var seededSpecification: JobSpecification?
    /// One status script per created job (the last script repeats for any
    /// further jobs). Within a script, the last status repeats.
    var jobStatusScripts: [[CCStatus]] = [[.processing, .finished]]
    var jobStatusScript: [CCStatus] {
        get { jobStatusScripts[0] }
        set { jobStatusScripts = [newValue] }
    }
    /// `code` of the failed processing task. `nil` sends `"code": null`, which
    /// is what CloudConvert does when an engine cannot convert the file.
    var failureCode: String? = nil
    var exportFiles: [(filename: String, size: Int64?, url: String)] = [(filename: "output.pdf", size: 10, url: "https://storage.example/output.pdf")]
    var getJobErrors: [CloudConvertError] = []
    var deletedJobIDs: [String] = []
    /// Whether storage has received the upload. When set, upload tasks stay
    /// `waiting` until it returns true, like the real API. `nil`: always true.
    var serverHasUpload: (@Sendable () -> Bool)?
    /// When set, `getJob` fails like a response that cannot be parsed.
    var getJobAlwaysUndecodable = false
    /// When true, created jobs come back without upload forms.
    var omitUploadForms = false
    /// Awaited inside `createJob` after the job was created server-side and
    /// before the response arrives (e.g. to cancel mid-request).
    var createJobHook: (@Sendable (_ jobID: String) async throws -> Void)?
    /// Awaited at the start of every `getJob` (e.g. to hang one call).
    var getJobHook: (@Sendable (_ jobID: String) async throws -> Void)?
    /// Seconds from now, by the device clock, until upload forms expire.
    /// Negative: the device clock runs that far ahead of the server's.
    var formExpiresIn: TimeInterval = 3600
    var createdJobIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return (0..<createdJobCount).map { "job-\($0 + 1)" }
    }
    var deletedJobIDsSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return deletedJobIDs
    }
    /// Every job id `getJob` was asked for, in order.
    var polledJobIDs: [String] { locked { polled } }
    private(set) var pollCount = 0
    private var polled: [String] = []
    private var statusIndex = 0
    private var createdJobCount = 0

    func createJob(_ specification: JobSpecification) async throws -> CCJob {
        lock.lock()
        if let createJobError { lock.unlock(); throw createJobError }
        createdSpecifications.append(specification)
        createdJobCount += 1
        statusIndex = 0
        let id = "job-\(createdJobCount)"
        let hook = createJobHook
        let job = Result { try makeJob(id: id, specification: specification, status: .waiting, includeForms: !omitUploadForms) }
        lock.unlock()
        if let hook { try await hook(id) }
        return try job.get()
    }

    func getJob(id: String) async throws -> CCJob {
        if let hook = locked({ getJobHook }) { try await hook(id) }
        return try locked {
            pollCount += 1
            polled.append(id)
            if getJobAlwaysUndecodable {
                throw CloudConvertError.decoding(reason: "getJob: DecodingError.dataCorrupted: not JSON")
            }
            if !getJobErrors.isEmpty { throw getJobErrors.removeFirst() }
            guard let spec = createdSpecifications.last ?? seededSpecification else {
                throw CloudConvertError.notFound(nil)
            }
            let script = jobStatusScripts[max(0, min(createdJobCount - 1, jobStatusScripts.count - 1))]
            let status = script[min(statusIndex, script.count - 1)]
            statusIndex += 1
            return try makeJob(id: id, specification: spec, status: status, includeForms: true)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    func deleteJob(id: String) async throws {
        lock.lock(); defer { lock.unlock() }
        deletedJobIDs.append(id)
    }

    func listJobs(_ filter: JobsFilter) async throws -> CCPage<CCJob> { CCPage(data: [], meta: nil) }
    func getTask(id: String) async throws -> CCTask { fatalError("not scripted") }
    func retryTask(id: String) async throws -> CCTask { fatalError("not scripted") }
    func cancelTask(id: String) async throws -> CCTask { fatalError("not scripted") }
    func deleteTask(id: String) async throws {}
    func operations(filter: OperationsFilter) async throws -> [CCOperation] { [] }
    func convertFormats(filter: OperationsFilter) async throws -> [CCOperation] { [] }
    func currentUser() async throws -> CCUser { fatalError("not scripted") }

    private func makeJob(id: String, specification: JobSpecification, status: CCStatus, includeForms: Bool) throws -> CCJob {
        var tasks: [[String: Any]] = []
        for task in specification.tasks {
            let isProcessing = !task.isImport && !task.isExport
            let taskStatus: String
            switch status {
            case .error: taskStatus = task.isImport ? "finished" : "error"   // the export fails with INPUT_TASK_FAILED
            case .finished: taskStatus = "finished"
            case .waiting: taskStatus = "waiting"                      // fresh job: nothing uploaded yet
            case .processing: taskStatus = task.isImport ? "finished" : "waiting"
            }
            let uploadArrived = serverHasUpload?() ?? true
            let taskStatusAsSeen = task.isUpload && !uploadArrived ? "waiting" : taskStatus
            var object: [String: Any] = [
                "id": "task-\(task.name)",
                "name": task.name,
                "operation": task.operation,
                "status": taskStatusAsSeen,
            ]
            if task.isUpload, includeForms {
                object["result"] = ["form": ["url": "https://upload.example/\(task.name)",
                                             "parameters": ["expires": "\(Int(Date().timeIntervalSince1970 + formExpiresIn))",
                                                            "max_file_size": "10000000000",
                                                            "signature": "sig"]]]
            }
            // Like the real API, only the export task's files carry a `url`;
            // processing and finished upload tasks list files by name and size.
            if task.isExport, status == .finished {
                object["result"] = ["files": exportFiles.map { file -> [String: Any] in
                    var f: [String: Any] = ["filename": file.filename, "url": file.url]
                    if let size = file.size { f["size"] = size }
                    return f
                }]
            } else if isProcessing, status == .finished {
                object["result"] = ["files": exportFiles.map { ["filename": $0.filename, "size": $0.size ?? 0] }]
            } else if task.isUpload, taskStatus == "finished", status != .waiting {
                object["result"] = ["files": [["filename": "input.bin", "size": 1024]]]
            }
            if status == .error, isProcessing {
                object["code"] = failureCode ?? NSNull()
                object["message"] = failureCode == nil ? "Conversion failed" : "scripted failure"
            } else if status == .error, task.isExport {
                object["code"] = "INPUT_TASK_FAILED"
                object["message"] = "Input task has failed"
            }
            tasks.append(object)
        }
        let json: [String: Any] = ["data": ["id": id, "status": status.rawValue, "tasks": tasks,
                                            "created_at": "2026-01-01T00:00:00.000000Z"]]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try CCDateDecoding.makeDecoder().decode(CCDataEnvelope<CCJob>.self, from: data).data
    }
}

// MARK: - Fake transfers

final class FakeTransfers: FileTransferring, @unchecked Sendable {

    private let lock = NSLock()
    var uploadStatuses: [Int] = [201]
    var downloadStatuses: [Int] = [200]
    var downloadContent = Data("converted".utf8)
    var uploadDelay: TimeInterval = 0
    /// The next N uploads reach storage but their response is lost (timeout).
    var lostResponses = 0
    private(set) var receivedUploads = 0
    var receivedUploadsSnapshot: Int { lock.lock(); defer { lock.unlock() }; return receivedUploads }
    private(set) var uploads: [(id: String, bodySize: Int64)] = []
    private(set) var downloads: [String] = []
    private(set) var cancelled: [String] = []

    func upload(id: String, request: URLRequest, bodyFile: URL,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        let size = (try? FileManager.default.attributesOfItem(atPath: bodyFile.path)[.size] as? Int64) ?? 0
        lock.lock()
        uploads.append((id, size))
        let status = uploadStatuses.count > 1 ? uploadStatuses.removeFirst() : uploadStatuses[0]
        let loseResponse = lostResponses > 0
        if loseResponse { lostResponses -= 1 }
        lock.unlock()
        if uploadDelay > 0 { try await Task.sleep(nanoseconds: UInt64(uploadDelay * 1_000_000_000)) }
        try Task.checkCancellation()
        if (200...299).contains(status) { lock.lock(); receivedUploads += 1; lock.unlock() }
        if loseResponse { throw URLError(.timedOut) }
        progress(TransferProgress(completedBytes: size / 2, totalBytes: size))
        progress(TransferProgress(completedBytes: size, totalBytes: size))
        return TransferOutcome(status: status, responseBody: nil, fileURL: nil, errorDescription: nil, urlErrorCode: nil, finishedAt: Date())
    }

    func download(id: String, request: URLRequest, destination: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        lock.lock()
        downloads.append(id)
        let status = downloadStatuses.count > 1 ? downloadStatuses.removeFirst() : downloadStatuses[0]
        lock.unlock()
        try Task.checkCancellation()
        var fileURL: URL?
        if (200...299).contains(status) {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try downloadContent.write(to: destination)
            fileURL = destination
        }
        progress(TransferProgress(completedBytes: Int64(downloadContent.count), totalBytes: Int64(downloadContent.count)))
        return TransferOutcome(status: status, responseBody: nil, fileURL: fileURL, errorDescription: nil, urlErrorCode: nil, finishedAt: Date())
    }

    /// Transfers a previous launch started, as `awaitExistingTransfer` finds
    /// them: what re-attaching to one returns or throws (a `BackgroundTransferManager`
    /// throws for a failure it saw happen, and returns the outcome of one that
    /// finished while the app was not running). `nil`: every one is lost.
    var reattach: (@Sendable (_ id: String) async throws -> TransferOutcome)?
    /// Ids the engine tried to re-attach to.
    var reattached: [String] { locked { reattachedIDs } }
    private var reattachedIDs: [String] = []

    func awaitExistingTransfer(id: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        let script = locked { () -> (@Sendable (String) async throws -> TransferOutcome)? in
            reattachedIDs.append(id)
            return reattach
        }
        guard let script else { throw CloudConvertError.transferLost(id: id) }
        return try await script(id)
    }

    func cancel(id: String) { lock.lock(); cancelled.append(id); lock.unlock() }
    func forget(id: String) {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

// MARK: - Connectivity fakes

struct AlwaysOnline: ConnectivityMonitoring {
    var isConnected: Bool { get async { true } }
    var isExpensive: Bool { get async { false } }
    func waitUntilConnected(timeout: TimeInterval) async throws {}
    func changes() -> AsyncStream<Bool> { AsyncStream { $0.yield(true); $0.finish() } }
}

/// Offline for good: every wait times out immediately.
struct AlwaysOffline: ConnectivityMonitoring {
    var isConnected: Bool { get async { false } }
    var isExpensive: Bool { get async { false } }
    func waitUntilConnected(timeout: TimeInterval) async throws { throw CloudConvertError.notConnected }
    func changes() -> AsyncStream<Bool> { AsyncStream { $0.yield(false); $0.finish() } }
}

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

// MARK: - Helpers

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

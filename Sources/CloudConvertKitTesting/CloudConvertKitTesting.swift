//  Fakes for the API client, the transfer layer and connectivity, so an app
//  (or a package that wraps this one) can test its conversions without a network:
//
//      let api = FakeCloudConvertAPI()
//      api.jobStatusScript = [.processing, .finished]
//      let engine = ConversionEngine(configuration: configuration, api: api,
//                                    transfers: FakeFileTransfers(), connectivity: AlwaysOnline(),
//                                    store: nil)
//

import Foundation
import CloudConvertKit

// MARK: - Fake API

/// Scripted API: each call to `getJob` returns the next status in `statuses`.
public final class FakeCloudConvertAPI: CloudConvertAPIClient, @unchecked Sendable {

    public init() {}


    public struct ScriptedTask {
        public var name: String
        public var operation: String
        public var status: CCStatus
        public var code: String? = nil
        public var message: String? = nil
        public var form: (url: String, params: [String: String])? = nil
        public var files: [(filename: String, size: Int64?, url: String)] = []

        public init(name: String, operation: String, status: CCStatus) {
            self.name = name
            self.operation = operation
            self.status = status
        }
    }

    private let lock = NSLock()
    public var createJobError: CloudConvertError?
    /// The jobs created, in order.
    public var createdSpecifications: [JobSpecification] { locked { created } }
    private var created: [JobSpecification] = []
    /// Specification used by `getJob` when no job was created in this run
    /// (simulates a job that exists on the server from a previous launch).
    public var seededSpecification: JobSpecification?
    /// One status script per created job (the last script repeats for any
    /// further jobs). Within a script, the last status repeats.
    public var jobStatusScripts: [[CCStatus]] = [[.processing, .finished]]
    public var jobStatusScript: [CCStatus] {
        get { jobStatusScripts[0] }
        set { jobStatusScripts = [newValue] }
    }
    /// `code` of the failed processing task. `nil` sends `"code": null`, which
    /// is what CloudConvert does when an engine cannot convert the file.
    public var failureCode: String? = nil
    public var exportFiles: [(filename: String, size: Int64?, url: String)] = [(filename: "output.pdf", size: 10, url: "https://storage.example/output.pdf")]
    public var getJobErrors: [CloudConvertError] = []
    /// The jobs deleted, in order.
    public var deletedJobIDs: [String] { locked { deleted } }
    private var deleted: [String] = []
    /// Whether storage has received the upload. When set, upload tasks stay
    /// `waiting` until it returns true, like the real API. `nil`: always true.
    public var serverHasUpload: (@Sendable () -> Bool)?
    /// When set, `getJob` fails like a response that cannot be parsed.
    public var getJobAlwaysUndecodable = false
    /// When true, created jobs come back without upload forms.
    public var omitUploadForms = false
    /// Awaited inside `createJob` after the job was created server-side and
    /// before the response arrives (e.g. to cancel mid-request).
    public var createJobHook: (@Sendable (_ jobID: String) async throws -> Void)?
    /// Awaited at the start of every `getJob` (e.g. to hang one call).
    public var getJobHook: (@Sendable (_ jobID: String) async throws -> Void)?
    /// Seconds from now, by the device clock, until upload forms expire.
    /// Negative: the device clock runs that far ahead of the server's.
    public var formExpiresIn: TimeInterval = 3600
    /// `credits` of each finished processing task.
    public var taskCredits: Int?
    public var createdJobIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return (0..<createdJobCount).map { "job-\($0 + 1)" }
    }
    public var deletedJobIDsSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return deleted
    }
    /// Every job id `getJob` was asked for, in order.
    public var polledJobIDs: [String] { locked { polled } }
    public var pollCount: Int { locked { polls } }
    private var polls = 0
    private var polled: [String] = []
    private var statusIndex = 0
    private var createdJobCount = 0

    public func createJob(_ specification: JobSpecification) async throws -> CCJob {
        let (id, hook, job) = try locked { () throws -> (String, (@Sendable (String) async throws -> Void)?, Result<CCJob, Error>) in
            if let createJobError { throw createJobError }
            created.append(specification)
            createdJobCount += 1
            statusIndex = 0
            let id = "job-\(createdJobCount)"
            return (id, createJobHook, Result { try makeJob(id: id, specification: specification, status: .waiting, includeForms: !omitUploadForms) })
        }
        if let hook { try await hook(id) }
        return try job.get()
    }

    public func getJob(id: String) async throws -> CCJob {
        if let hook = locked({ getJobHook }) { try await hook(id) }
        return try locked {
            polls += 1
            polled.append(id)
            if getJobAlwaysUndecodable {
                throw CloudConvertError.decoding(reason: "getJob: DecodingError.dataCorrupted: not JSON")
            }
            if !getJobErrors.isEmpty { throw getJobErrors.removeFirst() }
            guard let spec = created.last ?? seededSpecification else {
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

    public func deleteJob(id: String) async throws {
        locked { deleted.append(id) }
    }

    public func listJobs(_ filter: JobsFilter) async throws -> CCPage<CCJob> { CCPage(data: [], meta: nil) }
    public func getTask(id: String) async throws -> CCTask { fatalError("not scripted") }
    public func retryTask(id: String) async throws -> CCTask { fatalError("not scripted") }
    public func cancelTask(id: String) async throws -> CCTask { fatalError("not scripted") }
    public func deleteTask(id: String) async throws {}
    /// `GET /operations` rows, by operation name.
    public var operationRows: [String: [CCOperation]] = [:]
    /// `GET /convert/formats` rows.
    public var conversions: [CCOperation] = []
    /// When set, `convertFormats` fails with it.
    public var convertFormatsError: CloudConvertError?
    public var convertFormatsCalls: Int { locked { formatCalls } }
    private var formatCalls = 0
    /// `GET /users/me`; nil: fails with 403 (no `user.read` scope).
    public var user: CCUser?

    public func operations(filter: OperationsFilter) async throws -> [CCOperation] {
        locked { filter.operation.map { operationRows[$0] ?? [] } ?? operationRows.values.flatMap { $0 } }
    }
    public func convertFormats(filter: OperationsFilter) async throws -> [CCOperation] {
        try locked {
            formatCalls += 1
            if let convertFormatsError { throw convertFormatsError }
            return conversions
        }
    }
    public func currentUser() async throws -> CCUser {
        guard let user = locked({ user }) else { throw CloudConvertError.forbidden(nil) }
        return user
    }

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
                if let taskCredits { object["credits"] = taskCredits }
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

public final class FakeFileTransfers: FileTransferring, @unchecked Sendable {

    public init() {}


    private let lock = NSLock()
    public var uploadStatuses: [Int] = [201]
    public var downloadStatuses: [Int] = [200]
    public var downloadContent = Data("converted".utf8)
    public var uploadDelay: TimeInterval = 0
    /// The next N uploads reach storage but their response is lost (timeout).
    public var lostResponses = 0
    // What the fake saw. Read from tests while transfers run, so every
    // accessor takes the lock.
    private var receivedCount = 0
    private var uploadLog: [(id: String, bodySize: Int64)] = []
    private var downloadLog: [String] = []
    private var cancelLog: [String] = []
    /// Uploads that reached storage (2xx).
    public var receivedUploads: Int { locked { receivedCount } }
    public var receivedUploadsSnapshot: Int { receivedUploads }
    public var uploads: [(id: String, bodySize: Int64)] { locked { uploadLog } }
    public var downloads: [String] { locked { downloadLog } }
    public var cancelled: [String] { locked { cancelLog } }
    /// The most uploads that were in flight at once.
    public var maxConcurrentUploads: Int { locked { peakUploads } }
    private var uploadsInFlight = 0
    private var peakUploads = 0

    public func upload(id: String, request: URLRequest, bodyFile: URL,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        let size = (try? FileManager.default.attributesOfItem(atPath: bodyFile.path)[.size] as? Int64) ?? 0
        let (status, loseResponse) = locked { () -> (Int, Bool) in
            uploadLog.append((id, size))
            uploadsInFlight += 1
            peakUploads = max(peakUploads, uploadsInFlight)
            let status = uploadStatuses.count > 1 ? uploadStatuses.removeFirst() : uploadStatuses[0]
            let loseResponse = lostResponses > 0
            if loseResponse { lostResponses -= 1 }
            return (status, loseResponse)
        }
        defer { locked { uploadsInFlight -= 1 } }
        if uploadDelay > 0 { try await Task.sleep(nanoseconds: UInt64(uploadDelay * 1_000_000_000)) }
        try Task.checkCancellation()
        if (200...299).contains(status) { locked { receivedCount += 1 } }
        if loseResponse { throw URLError(.timedOut) }
        progress(TransferProgress(completedBytes: size / 2, totalBytes: size))
        progress(TransferProgress(completedBytes: size, totalBytes: size))
        return TransferOutcome(status: status, responseBody: nil, fileURL: nil, errorDescription: nil, urlErrorCode: nil, finishedAt: Date())
    }

    public func download(id: String, request: URLRequest, destination: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        let status = locked { () -> Int in
            downloadLog.append(id)
            return downloadStatuses.count > 1 ? downloadStatuses.removeFirst() : downloadStatuses[0]
        }
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
    public var reattach: (@Sendable (_ id: String) async throws -> TransferOutcome)?
    /// Ids the engine tried to re-attach to.
    public var reattached: [String] { locked { reattachedIDs } }
    private var reattachedIDs: [String] = []

    public func awaitExistingTransfer(id: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        let script = locked { () -> (@Sendable (String) async throws -> TransferOutcome)? in
            reattachedIDs.append(id)
            return reattach
        }
        guard let script else { throw CloudConvertError.transferLost(id: id) }
        return try await script(id)
    }

    public func cancel(id: String) { locked { cancelLog.append(id) } }
    public func forget(id: String) {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

// MARK: - Connectivity fakes

public struct AlwaysOnline: ConnectivityMonitoring {
    public init() {}
    public var isConnected: Bool { get async { true } }
    public var isExpensive: Bool { get async { false } }
    public func waitUntilConnected(timeout: TimeInterval) async throws {}
    public func changes() -> AsyncStream<Bool> { AsyncStream { $0.yield(true); $0.finish() } }
}

/// Offline for good: every wait times out immediately.
public struct AlwaysOffline: ConnectivityMonitoring {
    public init() {}
    public var isConnected: Bool { get async { false } }
    public var isExpensive: Bool { get async { false } }
    public func waitUntilConnected(timeout: TimeInterval) async throws { throw CloudConvertError.notConnected }
    public func changes() -> AsyncStream<Bool> { AsyncStream { $0.yield(false); $0.finish() } }
}


/// Connectivity a test switches: `isConnected = false`, then `true` again.
/// Waits end when it comes back; `changes()` reports every switch.
public final class FakeConnectivity: ConnectivityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var connected: Bool
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init(connected: Bool = true) { self.connected = connected }

    public var isConnected: Bool {
        get { lock.lock(); defer { lock.unlock() }; return connected }
        set {
            lock.lock()
            let changed = connected != newValue
            connected = newValue
            let resumed = newValue ? Array(waiters.values) : []
            if newValue { waiters.removeAll() }
            let streams = changed ? Array(subscribers.values) : []
            lock.unlock()
            resumed.forEach { $0.resume() }
            streams.forEach { $0.yield(newValue) }
        }
    }

    public var isExpensive: Bool { get async { false } }

    /// Waits until connected, or throws `.notConnected` after `timeout`.
    public func waitUntilConnected(timeout: TimeInterval) async throws {
        let id = UUID()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            self.resumeWaiter(id)
        }
        defer { timer.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if connected { lock.unlock(); continuation.resume(); return }
            waiters[id] = continuation
            lock.unlock()
        }
        if !isConnected { throw CloudConvertError.notConnected }
    }

    public func changes() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            subscribers[id] = continuation
            let current = connected
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.subscribers[id] = nil; self.lock.unlock()
            }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        lock.lock(); let waiter = waiters.removeValue(forKey: id); lock.unlock()
        waiter?.resume()
    }
}

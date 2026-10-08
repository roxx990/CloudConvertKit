//  Uploads and downloads on a background `URLSession`, bridged to
//  async/await. Transfers survive the app being suspended or terminated:
//  every transfer is recorded on disk with its destination, and outcomes are
//  persisted when the delegate fires so a relaunched app can pick them up.
//
//  Wire-up in the app (see README):
//
//      func application(_ application: UIApplication,
//                       handleEventsForBackgroundURLSession identifier: String,
//                       completionHandler: @escaping () -> Void) {
//          BackgroundTransferManager.shared(for: identifier)?
//              .setBackgroundCompletionHandler(completionHandler)
//      }
//

import Foundation

public struct TransferProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64

    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

public enum TransferKind: String, Codable, Sendable {
    case upload
    case download
}

/// What a finished transfer produced.
public struct TransferOutcome: Codable, Equatable, Sendable {
    public var status: Int?
    /// Response body for uploads (truncated to 64 KB), nil for downloads.
    public var responseBody: Data?
    /// Final location of a downloaded file.
    public var fileURL: URL?
    public var errorDescription: String?
    public var urlErrorCode: Int?
    public var finishedAt: Date

    public init(status: Int?, responseBody: Data?, fileURL: URL?, errorDescription: String?, urlErrorCode: Int?, finishedAt: Date) {
        self.status = status
        self.responseBody = responseBody
        self.fileURL = fileURL
        self.errorDescription = errorDescription
        self.urlErrorCode = urlErrorCode
        self.finishedAt = finishedAt
    }

    public var succeeded: Bool {
        errorDescription == nil && urlErrorCode == nil && (status.map { (200...299).contains($0) } ?? false)
    }
}

public struct PersistedTransfer: Codable, Equatable, Sendable {
    public var id: String
    public var kind: TransferKind
    public var destination: URL?
    public var bodyFile: URL?
    public var createdAt: Date
    public var outcome: TransferOutcome?
}

public protocol FileTransferring: Sendable {
    func upload(id: String, request: URLRequest, bodyFile: URL,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome
    func download(id: String, request: URLRequest, destination: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome
    /// Re-attaches to a transfer started in a previous launch.
    func awaitExistingTransfer(id: String,
                               progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome
    func cancel(id: String)
    func forget(id: String)
}

public final class BackgroundTransferManager: NSObject, FileTransferring, @unchecked Sendable {

    // MARK: Registry of managers per identifier (one per app in practice)

    private final class Registry: @unchecked Sendable {
        /// Recursive: a manager created by `manager(for:orMake:)` registers
        /// itself from its initialiser while the lock is held.
        private let lock = NSRecursiveLock()
        private var managers: [String: BackgroundTransferManager] = [:]

        subscript(identifier: String) -> BackgroundTransferManager? {
            get { lock.lock(); defer { lock.unlock() }; return managers[identifier] }
            set { lock.lock(); managers[identifier] = newValue; lock.unlock() }
        }

        func manager(for identifier: String, orMake make: () -> BackgroundTransferManager) -> BackgroundTransferManager {
            lock.lock(); defer { lock.unlock() }
            return managers[identifier] ?? make()
        }
    }

    private static let registry = Registry()

    /// The manager created for `identifier`, if any. A background session
    /// identifier must only be instantiated once per process; the engine uses
    /// this to reuse an existing manager.
    public static func shared(for identifier: String) -> BackgroundTransferManager? {
        registry[identifier]
    }

    /// The manager for `identifier`, made by `make` if there is none yet.
    /// Looking up and creating are one step, so engines created at the same
    /// time never open two sessions with the same identifier.
    static func shared(for identifier: String, orMake make: () -> BackgroundTransferManager) -> BackgroundTransferManager {
        registry.manager(for: identifier, orMake: make)
    }

    // MARK: Types

    private final class Entry {
        let id: String
        let kind: TransferKind
        var task: URLSessionTask?
        var continuation: CheckedContinuation<TransferOutcome, Error>?
        var progress: (@Sendable (TransferProgress) -> Void)?
        var responseData = Data()
        var destination: URL?
        var movedFileURL: URL?

        init(id: String, kind: TransferKind) {
            self.id = id
            self.kind = kind
        }
    }

    // MARK: State

    private let identifier: String
    private let logger: any CloudConvertLogging
    private let registryFileURL: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var persisted: [String: PersistedTransfer] = [:]
    /// Transfers `cancel(id:)` was asked to stop. Any other cancellation came
    /// from the system (iOS cancels background transfers when the user
    /// force-quits the app): the transfer is lost, the user cancelled nothing.
    private var cancelRequested: Set<String> = []
    private var backgroundCompletionHandler: (@Sendable () -> Void)?
    private var reattached = false

    /// Created in `init`, before the manager can be found through
    /// `shared(for:)`. Internal so tests can swap in a stubbed session.
    lazy var session: URLSession = {
        let configuration: URLSessionConfiguration
        if usesBackgroundSession {
            configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.shouldUseExtendedBackgroundIdleMode = true
        } else {
            configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
        }
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.timeoutIntervalForRequest = 60
        configuration.allowsCellularAccess = allowsCellularAccess
        configuration.networkServiceType = .responsiveData
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private let usesBackgroundSession: Bool
    private let allowsCellularAccess: Bool
    private let resourceTimeout: TimeInterval

    // MARK: Init

    public init(identifier: String,
                registryDirectory: URL,
                usesBackgroundSession: Bool = true,
                allowsCellularAccess: Bool = true,
                resourceTimeout: TimeInterval = 6 * 60 * 60,
                logger: any CloudConvertLogging = OSLogCloudConvertLogger()) {
        self.identifier = identifier
        self.usesBackgroundSession = usesBackgroundSession
        self.allowsCellularAccess = allowsCellularAccess
        self.resourceTimeout = resourceTimeout
        self.logger = logger
        self.registryFileURL = registryDirectory.appendingPathComponent("transfers-\(identifier).json")
        super.init()
        loadRegistry()
        purge()
        // Creating the session early re-connects to tasks from a previous
        // launch. It must exist before another thread can reach the manager:
        // two threads initialising the lazy property would open two sessions.
        _ = session
        Self.registry[identifier] = self
        reattachToRunningTasks()
    }

    /// Store the system's completion handler; it is invoked once all
    /// background events for this session have been delivered.
    public func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        locked { backgroundCompletionHandler = handler }
    }

    // MARK: FileTransferring

    public func upload(id: String, request: URLRequest, bodyFile: URL,
                       progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        try await start(id: id, kind: .upload, destination: nil, bodyFile: bodyFile, progress: progress) { session in
            var request = request
            request.httpBody = nil
            return session.uploadTask(with: request, fromFile: bodyFile)
        }
    }

    public func download(id: String, request: URLRequest, destination: URL,
                         progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        try await start(id: id, kind: .download, destination: destination, bodyFile: nil, progress: progress) { session in
            session.downloadTask(with: request)
        }
    }

    public func awaitExistingTransfer(id: String,
                                      progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        // 1. Already finished while we were away? 2. Still running (re-attached at launch)?
        let (finished, running): (TransferOutcome?, Bool) = locked { (persisted[id]?.outcome, entries[id] != nil) }
        if let finished { return finished }
        if running { return try await attach(id: id, progress: progress) }

        // 3. Ask the session; tasks can be delivered slightly after launch.
        let tasks = await session.allTasks
        if let task = tasks.first(where: { $0.taskDescription == id }) {
            locked {
                let kind = persisted[id]?.kind ?? (task is URLSessionDownloadTask ? .download : .upload)
                let entry = Entry(id: id, kind: kind)
                entry.task = task
                entry.destination = persisted[id]?.destination
                entries[id] = entry
            }
            return try await attach(id: id, progress: progress)
        }

        throw CloudConvertError.transferLost(id: id)
    }

    public func cancel(id: String) {
        let task: URLSessionTask? = locked {
            guard let task = entries[id]?.task else { return nil }
            cancelRequested.insert(id)
            return task
        }
        task?.cancel()
    }

    public func forget(id: String) {
        locked {
            entries.removeValue(forKey: id)
            persisted.removeValue(forKey: id)
            cancelRequested.remove(id)
            saveRegistryLocked()
        }
    }

    /// Drops persisted records older than `age` (their jobs are long gone).
    public func purge(olderThan age: TimeInterval = 48 * 60 * 60) {
        locked {
            let cutoff = Date().addingTimeInterval(-age)
            persisted = persisted.filter { $0.value.createdAt > cutoff }
            saveRegistryLocked()
        }
    }

    // MARK: Starting & attaching

    private func start(id: String,
                       kind: TransferKind,
                       destination: URL?,
                       bodyFile: URL?,
                       progress: @escaping @Sendable (TransferProgress) -> Void,
                       makeTask: (URLSession) -> URLSessionTask) async throws -> TransferOutcome {
        let entry = Entry(id: id, kind: kind)
        entry.destination = destination
        entry.progress = progress
        let alreadyRunning: Bool = locked {
            if entries[id] != nil { return true }
            entries[id] = entry
            persisted[id] = PersistedTransfer(id: id, kind: kind, destination: destination, bodyFile: bodyFile, createdAt: Date(), outcome: nil)
            saveRegistryLocked()
            return false
        }
        if alreadyRunning {
            // A transfer with this id is already running; join it.
            return try await attach(id: id, progress: progress)
        }

        let task = makeTask(session)
        task.taskDescription = id
        locked { entry.task = task }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransferOutcome, Error>) in
                lock.lock()
                // The calling task may already have been cancelled, in which
                // case `onCancel` ran first, the URLSession task was cancelled
                // and the delegate has (or will) finish the entry without us,
                // taking the cancel request with it: the cancellation is ours.
                if let outcome = persisted[id]?.outcome {
                    let requested = cancelRequested.remove(id) != nil || Task.isCancelled
                    lock.unlock()
                    continuation.resume(with: Self.result(of: outcome, id: id, kind: kind, cancelRequested: requested))
                    return
                }
                guard entries[id] === entry else {
                    lock.unlock()
                    continuation.resume(throwing: Task.isCancelled ? CloudConvertError.cancelled : CloudConvertError.transferLost(id: id))
                    return
                }
                entry.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel(id: id)
        }
    }

    private func attach(id: String,
                        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransferOutcome, Error>) in
                lock.lock()
                if let outcome = persisted[id]?.outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                    return
                }
                guard let entry = entries[id] else {
                    lock.unlock()
                    continuation.resume(throwing: CloudConvertError.transferLost(id: id))
                    return
                }
                if entry.continuation != nil {
                    // Only one waiter per transfer is supported; a second one
                    // would silently steal the result.
                    lock.unlock()
                    continuation.resume(throwing: CloudConvertError.invalidRequest(reason: "Transfer \(id) already has a waiter."))
                    return
                }
                entry.continuation = continuation
                entry.progress = progress
                lock.unlock()
            }
        } onCancel: {
            self.cancel(id: id)
        }
    }

    private func reattachToRunningTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.locked {
                for task in tasks {
                    guard let id = task.taskDescription, self.entries[id] == nil else { continue }
                    let kind: TransferKind = self.persisted[id]?.kind ?? (task is URLSessionDownloadTask ? .download : .upload)
                    let entry = Entry(id: id, kind: kind)
                    entry.task = task
                    entry.destination = self.persisted[id]?.destination
                    self.entries[id] = entry
                }
                self.reattached = true
            }
            self.logger.info("Re-attached to \(tasks.count) background transfer(s)")
        }
    }

    // MARK: Completion

    private func finish(id: String, outcome: TransferOutcome) {
        let (entry, continuation, requested): (Entry?, CheckedContinuation<TransferOutcome, Error>?, Bool) = locked {
            let entry = entries.removeValue(forKey: id)
            // Only transfers that are still registered get their outcome persisted;
            // one that was forgotten (cancelled / aborted) must not be resurrected.
            if var record = persisted[id] {
                record.outcome = outcome
                persisted[id] = record
                saveRegistryLocked()
            }
            let continuation = entry?.continuation
            entry?.continuation = nil
            return (entry, continuation, cancelRequested.remove(id) != nil)
        }

        if let continuation, let entry {
            continuation.resume(with: Self.result(of: outcome, id: id, kind: entry.kind, cancelRequested: requested))
        }
    }

    /// What the waiter of a finished transfer gets. Only a cancellation that
    /// `cancel(id:)` asked for is `.cancelled`; one the system made (iOS
    /// cancels background transfers when the user force-quits the app) is
    /// `.transferLost`, so the transfer is started again and the job kept.
    static func result(of outcome: TransferOutcome, id: String, kind: TransferKind,
                       cancelRequested: Bool) -> Result<TransferOutcome, CloudConvertError> {
        if let code = outcome.urlErrorCode {
            let urlCode = URLError.Code(rawValue: code)
            if urlCode == .cancelled { return .failure(cancelRequested ? .cancelled : .transferLost(id: id)) }
            return .failure(.wrap(URLError(urlCode), phase: kind == .download ? .downloading : .uploading))
        }
        if let description = outcome.errorDescription { return .failure(.storage(reason: description)) }
        return .success(outcome)
    }

    // MARK: Registry persistence

    private func loadRegistry() {
        guard let data = try? Data(contentsOf: registryFileURL),
              let decoded = try? JSONDecoder().decode([String: PersistedTransfer].self, from: data) else { return }
        persisted = decoded
    }

    private func saveRegistryLocked() {
        do {
            try FileManager.default.createDirectory(at: registryFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: registryFileURL, options: .atomic)
        } catch {
            logger.warning("Could not persist transfer registry: \(error.localizedDescription)")
        }
    }

    private func entry(for task: URLSessionTask) -> Entry? {
        guard let id = task.taskDescription else { return nil }
        return locked { entries[id] }
    }

    /// Synchronous critical section. Keeping `lock`/`unlock` inside a
    /// non-async helper is what makes it legal to call from async code.
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

// MARK: - URLSessionDelegate

extension BackgroundTransferManager: URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate, URLSessionDownloadDelegate {

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler: (@Sendable () -> Void)? = locked {
            let handler = backgroundCompletionHandler
            backgroundCompletionHandler = nil
            return handler
        }
        if let handler {
            DispatchQueue.main.async { handler() }
        }
    }

    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        logger.error("Background session invalidated: \(error?.localizedDescription ?? "no error")")
        // No `didCompleteWithError` follows invalidation; fail every waiter so
        // nothing hangs forever.
        let pending: [String: Entry] = locked {
            let pending = entries
            entries.removeAll()
            return pending
        }
        for (id, entry) in pending {
            entry.continuation?.resume(throwing: CloudConvertError.transferLost(id: id))
            entry.continuation = nil
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let entry = entry(for: task) else { return }
        let progress = locked { entry.progress }
        progress?(TransferProgress(completedBytes: totalBytesSent, totalBytes: totalBytesExpectedToSend))
    }

    /// Upload endpoints answer with a small body; keep a bounded prefix of it
    /// so a rejection can be reported with the server's own explanation.
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let entry = entry(for: dataTask) else { return }
        locked {
            if entry.responseData.count < 64 * 1024 { entry.responseData.append(data) }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let entry = entry(for: downloadTask) else { return }
        let progress = locked { entry.progress }
        progress?(TransferProgress(completedBytes: totalBytesWritten, totalBytes: totalBytesExpectedToWrite))
    }

    /// URLSession deletes `location` as soon as this method returns, so the
    /// file has to be moved synchronously here rather than on the waiting task.
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let (entry, destination): (Entry?, URL?) = locked {
            let entry = entries[id]
            return (entry, entry?.destination ?? persisted[id]?.destination)
        }

        guard let destination else {
            logger.error("Download \(id) finished but no destination is known; discarding")
            return
        }
        // Only keep the payload for successful responses; an error page is not a file.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { return }

        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            locked { entry?.movedFileURL = destination }
        } catch {
            // The description names the file: metadata, which the default logger keeps private.
            logger.error("Could not move download \(id) into place", metadata: ["error": error.localizedDescription])
        }
    }

    /// The single completion point for uploads and downloads alike, including
    /// tasks that finished while the app was not running.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }

        let (kind, movedFile, body): (TransferKind, URL?, Data?) = locked {
            let entry = entries[id]
            let kind = entry?.kind ?? persisted[id]?.kind ?? .upload
            // After a relaunch the delegate can fire before `entries` is rebuilt;
            // fall back to the persisted destination to find the moved file.
            let destination = entry?.destination ?? persisted[id]?.destination
            let movedFile = entry?.movedFileURL
                ?? destination.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            return (kind, movedFile, entry?.responseData)
        }

        let status = (task.response as? HTTPURLResponse)?.statusCode
        var outcome = TransferOutcome(status: status, responseBody: nil, fileURL: nil,
                                      errorDescription: nil, urlErrorCode: nil, finishedAt: Date())
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                outcome.urlErrorCode = nsError.code
            } else {
                outcome.errorDescription = nsError.localizedDescription
            }
            logger.warning("Transfer \(id) (\(kind.rawValue)) failed: \(nsError.domain) \(nsError.code)",
                           metadata: ["error": nsError.localizedDescription])
        } else {
            switch kind {
            case .upload:
                outcome.responseBody = body
            case .download:
                outcome.fileURL = movedFile
                if movedFile == nil, let status, (200...299).contains(status) {
                    outcome.errorDescription = "Downloaded file could not be stored."
                }
            }
            logger.info("Transfer \(id) (\(kind.rawValue)) completed with status \(status ?? -1)")
        }
        finish(id: id, outcome: outcome)
    }
}

//  Runs blocking file IO (staging a 1 GB video, writing a multipart body) on
//  a dedicated dispatch queue instead of a Swift-concurrency worker thread.
//  The cooperative pool has as many threads as cores; blocking one of them
//  for seconds starves every other task in the app, including the UI's.
//

import Foundation

/// A flag the blocking work can poll, since `Task.checkCancellation()` has
/// no task to check when running on a dispatch queue.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }
}

enum BlockingWork {

    private static let queue = DispatchQueue(label: "CloudConvertKit.BlockingWork",
                                             qos: .utility,
                                             attributes: .concurrent)

    /// Runs `body` on the IO queue and suspends the caller until it returns.
    /// Cancellation of the calling task before the work starts is honoured;
    /// use `runCancellable` when the work itself can be interrupted.
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await runCancellable { _ in try body() }
    }

    /// Like `run`, but `body` receives an `isCancelled` closure it can poll
    /// between chunks so a cancelled conversion stops copying immediately.
    static func runCancellable<T: Sendable>(
        _ body: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                queue.async {
                    if flag.isCancelled {
                        continuation.resume(throwing: CloudConvertError.cancelled)
                        return
                    }
                    continuation.resume(with: Result { try body { flag.isCancelled } })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}

//  Bounds how many conversions run at once. Starting a job per file and
//  uploading twenty of them in parallel is the quickest way to hit the
//  rate limit on job creation and to starve every upload of bandwidth; the
//  queue turns that into an orderly stream while still overlapping work.
//

import Foundation

public actor ConversionQueue {

    private let engine: ConversionEngine
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
    private var granted: Set<UUID> = []
    private var handles: [String: ConversionHandle] = [:]

    public init(engine: ConversionEngine, maxConcurrent: Int? = nil) {
        self.engine = engine
        self.maxConcurrent = max(1, maxConcurrent ?? engine.configuration.maxConcurrentConversions)
    }

    // MARK: Enqueueing

    /// Queues a conversion. The handle is live immediately; progress starts
    /// once a slot is free.
    public func enqueue(_ request: ConversionRequest) -> ConversionHandle {
        let engine = self.engine
        return schedule { id, progress in
            try await engine.convert(request, conversionID: id, progress: progress)
        }
    }

    /// Queues a hand-built job (see `JobBuilder`).
    public func enqueue(_ specification: JobSpecification,
                        output: OutputOptions = .default,
                        userInfo: [String: String] = [:]) -> ConversionHandle {
        let engine = self.engine
        return schedule { id, progress in
            try await engine.run(specification, output: output, userInfo: userInfo, conversionID: id, progress: progress)
        }
    }

    /// Queues several requests and returns their handles in the same order.
    public func enqueue(_ requests: [ConversionRequest]) -> [ConversionHandle] {
        requests.map { enqueue($0) }
    }

    // MARK: Control

    public func cancelAll() {
        handles.values.forEach { $0.cancel() }
    }

    public func cancel(id: String) {
        handles[id]?.cancel()
    }

    public var activeCount: Int { running }
    public var queuedCount: Int { waiters.count }

    // MARK: Internals

    private func schedule(
        _ body: @escaping @Sendable (_ conversionID: String, _ progress: @escaping ConversionProgressHandler) async throws -> ConversionResult
    ) -> ConversionHandle {
        let conversionID = UUID().uuidString
        let (stream, continuation) = ConversionEngine.makeProgressStream()

        let task = Task<ConversionResult, Error> {
            defer { continuation.finish() }
            do {
                try await self.acquireSlot()
            } catch {
                // Cancelled while queued: it never started, but still ends
                // with exactly one terminal stage.
                continuation.yield(ConversionProgress(conversionID: conversionID, stage: .cancelled, fractionCompleted: 0))
                throw error
            }
            defer { self.releaseSlot() }        // the Task inherits the actor's isolation
            return try await body(conversionID) { continuation.yield($0) }
        }

        let handle = ConversionHandle(id: conversionID, progress: stream, task: task)
        handles[conversionID] = handle
        Task { [weak self] in
            _ = try? await task.value
            await self?.forget(conversionID)
        }
        return handle
    }

    private func acquireSlot() async throws {
        if running < maxConcurrent {
            running += 1
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.removeWaiter(id) }
        }
        let ownsSlot = granted.remove(id) != nil
        if Task.isCancelled {
            if ownsSlot { releaseSlot() }
            throw CloudConvertError.cancelled
        }
        guard ownsSlot else { throw CloudConvertError.cancelled }
        // Resumed by `releaseSlot`, which handed its slot to us (`running` unchanged).
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            granted.insert(next.id)
            next.continuation.resume()          // slot is handed over: `running` stays the same
        } else {
            running = max(0, running - 1)
        }
    }

    private func removeWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume()
    }

    private func forget(_ id: String) {
        handles.removeValue(forKey: id)
    }
}

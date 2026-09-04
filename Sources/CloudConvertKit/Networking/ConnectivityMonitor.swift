//  Wraps `NWPathMonitor` so the engine can (a) skip a doomed request when the
//  device is offline and (b) suspend and automatically resume when the
//  connection comes back, instead of failing the whole conversion.
//

import Foundation
import Network

public protocol ConnectivityMonitoring: Sendable {
    var isConnected: Bool { get async }
    var isExpensive: Bool { get async }
    /// Suspends until the network is reachable or `timeout` elapses
    /// (throws `CloudConvertError.notConnected` on timeout).
    func waitUntilConnected(timeout: TimeInterval) async throws
    /// A stream of connectivity changes (`true` = connected). Emits the
    /// current value first.
    func changes() -> AsyncStream<Bool>
}

public actor ConnectivityMonitor: ConnectivityMonitoring {

    public static let shared = ConnectivityMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "CloudConvertKit.ConnectivityMonitor")
    /// `nil` until the monitor has reported at least once.
    private var connected: Bool?
    private var expensive = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var started = false

    public init() {}

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            let isExpensive = path.isExpensive
            guard let self else { return }
            Task { await self.update(connected: isSatisfied, expensive: isExpensive) }
        }
        monitor.start(queue: queue)
    }

    private func update(connected newValue: Bool, expensive newExpensive: Bool) {
        let previous = connected
        connected = newValue
        expensive = newExpensive
        if newValue {
            let pending = waiters
            waiters.removeAll()
            pending.values.forEach { $0.resume() }
        }
        if previous != newValue {
            subscribers.values.forEach { $0.yield(newValue) }
        }
    }

    public var isConnected: Bool {
        startIfNeeded()
        // Until the first report, assume connected: the request itself will
        // tell us, and we must never block on a reading we do not have.
        return connected ?? true
    }

    public var isExpensive: Bool {
        startIfNeeded()
        return expensive
    }

    public func waitUntilConnected(timeout: TimeInterval) async throws {
        startIfNeeded()
        if isConnected { return }

        let id = UUID()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.resumeWaiter(id: id)
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.resumeWaiter(id: id) }
        }
        timeoutTask.cancel()

        if Task.isCancelled { throw CloudConvertError.cancelled }
        if !isConnected { throw CloudConvertError.notConnected }
    }

    private func resumeWaiter(id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume()
        }
    }

    public nonisolated func changes() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    private func subscribe(id: UUID, continuation: AsyncStream<Bool>.Continuation) {
        startIfNeeded()
        subscribers[id] = continuation
        continuation.yield(isConnected)
    }

    private func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}

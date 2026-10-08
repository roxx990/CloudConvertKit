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
    /// Number of the newest path reading applied.
    private var lastReading = 0

    public init() {}

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        let readings = ReadingCounter()
        monitor.pathUpdateHandler = { [weak self] path in
            // The monitor reports one path at a time, but each hops onto the
            // actor in its own task, so they can arrive out of order. The
            // number lets `update` drop a stale one instead of applying it.
            let reading = readings.next()
            let isUsable = ConnectivityMonitor.isUsable(path.status)
            let isExpensive = path.isExpensive
            guard let self else { return }
            Task { await self.update(reading, connected: isUsable, expensive: isExpensive) }
        }
        monitor.start(queue: queue)
    }

    /// Only `.unsatisfied` is offline. `.requiresConnection` (an on-demand
    /// VPN, a cellular link that wakes up on use) comes up when a request is
    /// made, so refusing to make one would keep it down.
    static func isUsable(_ status: NWPath.Status) -> Bool {
        status != .unsatisfied
    }

    func update(_ reading: Int, connected newValue: Bool, expensive newExpensive: Bool) {
        guard reading > lastReading else { return }
        lastReading = reading
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
            try? await Task.sleep(seconds: timeout)
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

/// Numbers path readings in the order `NWPathMonitor` reports them.
private final class ReadingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

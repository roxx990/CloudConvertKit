//  Recorders, synchronisation and waiting. The helpers that wait give up
//  after a limit, so a regression fails instead of hanging the suite.
//

import Foundation
import XCTest
@testable import CloudConvertKit

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
    @discardableResult func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
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

/// Polls `condition` until it holds or `timeout` elapses.
func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
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

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, _ message: @autoclosure () -> String = "",
                       file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, message(), file: file, line: line)
}

func outcome(_ status: Int) -> TransferOutcome {
    TransferOutcome(status: status, responseBody: nil, fileURL: nil, errorDescription: nil, urlErrorCode: nil, finishedAt: Date())
}

//  A ready-made observable model for a "converting…" screen. Owns a queue,
//  mirrors every conversion as an `Item`, and exposes the operations a
//  processing screen needs (cancel one / all, retry failed, clear finished).
//  Use it directly or as a reference for your own view models.
//

import Foundation
import Combine
import CloudConvertKit

@MainActor
public final class ConversionViewModel: ObservableObject {

    public enum State: Equatable, Sendable {
        case queued
        case running
        case succeeded
        case failed
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .succeeded, .failed, .cancelled: return true
            case .queued, .running: return false
            }
        }
    }

    public struct Item: Identifiable, Equatable {
        public let id: String
        public let request: ConversionRequest
        public var state: State
        public var progress: ConversionProgress?
        public var result: ConversionResult?
        public var error: CloudConvertError?

        public var fractionCompleted: Double {
            switch state {
            case .succeeded: return 1
            case .queued: return 0
            default: return progress?.fractionCompleted ?? 0
            }
        }

        public var statusText: String {
            switch state {
            case .queued: return "Waiting…"
            case .running: return progress?.localizedStageDescription ?? "Starting…"
            case .succeeded: return "Done"
            case .failed: return error?.userFacingMessage ?? "Failed"
            case .cancelled: return "Cancelled"
            }
        }

        public static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id && lhs.state == rhs.state && lhs.progress == rhs.progress && lhs.result == rhs.result
        }
    }

    @Published public private(set) var items: [Item] = []

    private let engine: ConversionEngine
    private let queue: ConversionQueue
    private var observers: [String: Task<Void, Never>] = [:]

    public init(engine: ConversionEngine, maxConcurrent: Int? = nil) {
        self.engine = engine
        self.queue = ConversionQueue(engine: engine, maxConcurrent: maxConcurrent)
    }

    // MARK: Derived state

    public var isRunning: Bool { items.contains { !$0.state.isFinished } }
    public var succeeded: [Item] { items.filter { $0.state == .succeeded } }
    public var failed: [Item] { items.filter { $0.state == .failed } }

    /// Average progress across all items (finished items count as 1).
    public var overallFraction: Double {
        guard !items.isEmpty else { return 0 }
        return items.map(\.fractionCompleted).reduce(0, +) / Double(items.count)
    }

    // MARK: Commands

    /// Adds and starts one conversion per request.
    public func convert(_ requests: [ConversionRequest]) {
        for request in requests {
            Task { await enqueue(request) }
        }
    }

    public func convert(_ request: ConversionRequest) {
        convert([request])
    }

    public func cancel(id: String) {
        Task { await queue.cancel(id: id) }
    }

    public func cancelAll() {
        Task { await queue.cancelAll() }
    }

    /// Re-runs a failed or cancelled item with the same request.
    public func retry(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.isFinished else { return }
        let request = items[index].request
        items.remove(at: index)
        observers[id]?.cancel()
        observers[id] = nil
        Task { await enqueue(request) }
    }

    public func remove(id: String) {
        cancel(id: id)
        items.removeAll { $0.id == id }
        observers[id]?.cancel()
        observers[id] = nil
    }

    public func clearFinished() {
        for item in items where item.state.isFinished {
            observers[item.id]?.cancel()
            observers[item.id] = nil
        }
        items.removeAll { $0.state.isFinished }
    }

    // MARK: Internals

    private func enqueue(_ request: ConversionRequest) async {
        let handle = await queue.enqueue(request)
        items.append(Item(id: handle.id, request: request, state: .queued))

        observers[handle.id] = Task { [weak self] in
            for await progress in handle.progress {
                guard let self else { return }
                self.update(handle.id) { item in
                    item.progress = progress
                    switch progress.stage {
                    case .completed: item.state = .succeeded
                    case .failed: item.state = .failed
                    case .cancelled: item.state = .cancelled
                    default: item.state = .running
                    }
                }
            }
            do {
                let result = try await handle.result
                self?.update(handle.id) { item in
                    item.result = result
                    item.state = .succeeded
                }
            } catch {
                let ccError = CloudConvertError.wrap(error, phase: .preparing)
                self?.update(handle.id) { item in
                    item.error = ccError
                    if case .cancelled = ccError { item.state = .cancelled } else { item.state = .failed }
                }
            }
        }
    }

    private func update(_ id: String, _ body: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        body(&item)
        items[index] = item
    }
}

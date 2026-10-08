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
    private var handles: [String: ConversionHandle] = [:]
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
        if let handle = handles[id] {
            handle.cancel()
        } else {
            update(id) { if $0.state == .queued { $0.state = .cancelled } }    // still being resumed: `resume` stops it
        }
    }

    public func cancelAll() {
        items.forEach { cancel(id: $0.id) }
    }

    /// Re-runs a failed or cancelled item with the same request. An item that
    /// stopped with a resumable error (`CloudConvertError.isResumable`) is
    /// resumed instead: its job is still on CloudConvert, and running the
    /// request again would convert, and bill, the file a second time. If the
    /// app already resumed it (`resumePendingConversions()`), the item
    /// follows that run, or shows its result.
    public func retry(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.isFinished else { return }
        let item = items[index]
        forget(id)
        if item.error?.isResumable == true {
            items[index] = Item(id: id, request: item.request, state: .queued)
            Task { await resume(item) }
        } else {
            items.remove(at: index)
            Task { await enqueue(item.request) }
        }
    }

    public func remove(id: String) {
        cancel(id: id)
        discardResumable(items.filter { $0.id == id })
        items.removeAll { $0.id == id }
        forget(id)
    }

    public func clearFinished() {
        let finished = items.filter(\.state.isFinished)
        finished.forEach { forget($0.id) }
        discardResumable(finished)
        items.removeAll { $0.state.isFinished }
    }

    // MARK: Internals

    private func enqueue(_ request: ConversionRequest) async {
        let handle = await queue.enqueue(request)
        items.append(Item(id: handle.id, request: request, state: .queued))
        observe(handle)
    }

    private func resume(_ item: Item) async {
        let id = item.id
        let handle = await engine.resumePendingConversions(where: { $0.id == id }).first ?? engine.resumedConversion(id: id)
        guard items.first(where: { $0.id == id })?.state == .queued else {
            handle?.cancel()        // removed or cancelled meanwhile
            return
        }
        guard let handle else {
            // Neither kept nor resumed: it was discarded, or failed. Start over.
            items.removeAll { $0.id == id }
            await enqueue(item.request)
            return
        }
        observe(handle)
    }

    /// A conversion that stopped with a resumable error is kept for a
    /// resume. Removing its item gives it up, so its record and job go too.
    private func discardResumable(_ removed: [Item]) {
        let ids = removed.filter { $0.error?.isResumable == true }.map(\.id)
        guard !ids.isEmpty else { return }
        Task { for id in ids { await engine.discardPendingConversion(id: id) } }
    }

    private func observe(_ handle: ConversionHandle) {
        handles[handle.id] = handle
        observers[handle.id] = Task { [weak self] in
            for await progress in handle.progress {
                guard let self else { return }
                self.update(handle.id) { item in
                    item.progress = progress
                    // The final state is set below, with the result or error:
                    // `retry(id:)` must not see `.failed` before knowing
                    // whether the error is resumable.
                    if !progress.stage.isTerminal { item.state = .running }
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

    private func forget(_ id: String) {
        handles[id] = nil
        observers[id]?.cancel()
        observers[id] = nil
    }

    private func update(_ id: String, _ body: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        body(&item)
        items[index] = item
    }
}

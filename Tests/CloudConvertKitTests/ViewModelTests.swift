//  The SwiftUI adapter, CloudConvertKitUI.
//

import XCTest
@testable import CloudConvertKit
import CloudConvertKitUI

// MARK: - View model

@MainActor
final class ConversionViewModelTests: XCTestCase {

    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private struct Setup {
        let api: FakeAPI
        let transfers: FakeTransfers
        let network: DroppedNetwork
        let engine: ConversionEngine
        let model: ConversionViewModel
        let output: URL
        let id: String
    }

    /// A model whose only item stopped with a resumable error: the first
    /// status check found the device offline, and the network stayed away.
    private func keptItem(store: ((CloudConvertConfiguration) -> any ConversionRecordStoring)? = nil) async throws -> Setup {
        let api = FakeAPI(), transfers = FakeTransfers(), network = DroppedNetwork()
        api.serverHasUpload = { transfers.receivedUploadsSnapshot > 0 }
        api.getJobErrors = [.notConnected]
        let work = TestFiles.temporaryDirectory(), out = TestFiles.temporaryDirectory()
        directories += [work, out]
        let configuration = CloudConvertConfiguration.testing(workingDirectory: work, outputDirectory: out)
        let engine = ConversionEngine(configuration: configuration, api: api, transfers: transfers,
                                      connectivity: network, store: store?(configuration))
        let model = ConversionViewModel(engine: engine)
        model.convert(ConversionRequest.convert(try TestFiles.makeFile(named: "book.epub"), to: "mobi"))
        for _ in 0..<300 where model.items.first?.error?.isResumable != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let id = try XCTUnwrap(model.items.first?.id)
        XCTAssertEqual(model.items.first?.error?.isResumable, true, "precondition: the item was kept")
        return Setup(api: api, transfers: transfers, network: network, engine: engine, model: model, output: out, id: id)
    }

    private func waitUntilFinished(_ model: ConversionViewModel) async throws {
        for _ in 0..<300 where !(model.items.allSatisfy(\.state.isFinished) && !model.items.isEmpty) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The user retries the interrupted item, then taps Cancel while it runs.
    func testCancelReachesAnItemResumedByRetry() async throws {
        let s = try await keptItem()
        s.network.isBack = true
        let gate = Gate(), calls = Counter()
        s.api.getJobHook = { _ in if calls.next() == 1 { try await gate.wait() } }   // the resumed job's first check hangs

        s.model.retry(id: s.id)
        for _ in 0..<300 where calls.count < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(calls.count, 1, "precondition: the resumed conversion is running")

        s.model.cancel(id: s.id)
        try await waitUntilFinished(s.model)
        gate.open()

        XCTAssertEqual(s.model.items.first?.state, .cancelled)
        let pending = await s.engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty, "a cancelled conversion is not kept")
        XCTAssertEqual(s.transfers.downloads.count, 0)
    }

    /// With `resumesWhenOnline`, an item paused offline finishes by itself
    /// when the network returns, without the user retrying it.
    func testAnItemPausedOfflineFinishesWhenTheNetworkReturns() async throws {
        let api = FakeAPI(), transfers = FakeTransfers(), network = FakeConnectivity()
        api.serverHasUpload = { transfers.receivedUploadsSnapshot > 0 }
        api.getJobHook = { [api] _ in
            if network.isConnected, api.pollCount == 0 {
                network.isConnected = false
                api.getJobErrors = [.notConnected]
            }
        }
        let work = TestFiles.temporaryDirectory(), out = TestFiles.temporaryDirectory()
        directories += [work, out]
        var configuration = CloudConvertConfiguration.testing(workingDirectory: work, outputDirectory: out)
        configuration.resumesWhenOnline = true
        configuration.offlineWaitTimeout = 0.1
        let model = ConversionViewModel(engine: ConversionEngine(configuration: configuration, api: api,
                                                                 transfers: transfers, connectivity: network))

        model.convert(ConversionRequest.convert(try TestFiles.makeFile(named: "book.epub"), to: "mobi"))
        for _ in 0..<300 where model.items.first?.error?.isResumable != true { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.items.first?.state, .failed)

        api.getJobHook = nil
        network.isConnected = true
        for _ in 0..<300 where model.items.first?.state != .succeeded { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.items.first?.state, .succeeded)
        XCTAssertEqual(api.createdSpecifications.count, 1)
    }

    /// The user retries the interrupted item, then removes it while it runs.
    func testRemoveStopsAnItemResumedByRetry() async throws {
        let s = try await keptItem()
        s.network.isBack = true
        let gate = Gate(), calls = Counter()
        s.api.getJobHook = { _ in if calls.next() == 1 { try await gate.wait() } }

        s.model.retry(id: s.id)
        for _ in 0..<300 where calls.count < 1 { try await Task.sleep(nanoseconds: 10_000_000) }

        s.model.remove(id: s.id)
        XCTAssertTrue(s.model.items.isEmpty)
        try await Task.sleep(nanoseconds: 300_000_000)
        gate.open()
        try await Task.sleep(nanoseconds: 300_000_000)

        let outputs = (try? FileManager.default.contentsOfDirectory(atPath: s.output.path)) ?? []
        XCTAssertTrue(outputs.isEmpty, "the removed conversion kept running and saved \(outputs)")
        XCTAssertEqual(s.transfers.downloads.count, 0)
        XCTAssertEqual(s.api.deletedJobIDsSnapshot, ["job-1"], "the removed conversion's job is deleted")
    }

    /// The user cancels the item before the resume `retry(id:)` asked for
    /// has begun: it is stopped as soon as it starts.
    func testCancellingAnItemWhileItIsBeingResumedStopsIt() async throws {
        var held: HeldStore!
        let s = try await keptItem { configuration in
            held = HeldStore(directory: FileStorage(workingDirectory: configuration.workingDirectory,
                                                   outputDirectory: configuration.outputDirectory,
                                                   diskSpaceSafetyMargin: 0).recordsDirectory)
            return held
        }
        s.network.isBack = true
        let gate = Gate(), calls = Counter()
        s.api.getJobHook = { _ in if calls.next() == 1 { try await gate.wait() } }
        held.hold()

        s.model.retry(id: s.id)
        for _ in 0..<300 where !held.isHolding { try await Task.sleep(nanoseconds: 10_000_000) }
        s.model.cancel(id: s.id)
        XCTAssertEqual(s.model.items.first?.state, .cancelled)
        held.release()

        var pending = await s.engine.pendingConversions()
        for _ in 0..<300 where !pending.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
            pending = await s.engine.pendingConversions()
        }
        gate.open()
        XCTAssertTrue(pending.isEmpty, "the cancelled conversion was kept: \(pending.map(\.id))")
        XCTAssertEqual(s.model.items.first?.state, .cancelled)
        XCTAssertEqual(s.transfers.downloads.count, 0)
        XCTAssertEqual(s.api.createdSpecifications.count, 1)
    }

    /// The app resumes pending conversions itself (at launch, or when the
    /// network returns); the user also taps Retry on the failed row. The
    /// item follows that run: the file is not converted, and billed, twice.
    func testRetryWhileTheAppResumesItFollowsThatRun() async throws {
        let s = try await keptItem()
        s.network.isBack = true
        let gate = Gate(), calls = Counter()
        s.api.getJobHook = { _ in if calls.next() == 1 { try await gate.wait() } }

        let resumed = await s.engine.resumePendingConversions()
        XCTAssertEqual(resumed.map(\.id), [s.id])
        for _ in 0..<300 where calls.count < 1 { try await Task.sleep(nanoseconds: 10_000_000) }

        s.model.retry(id: s.id)
        try await Task.sleep(nanoseconds: 200_000_000)
        gate.open()
        let finished = try await XCTUnwrap(resumed.first).result
        try await waitUntilFinished(s.model)

        XCTAssertEqual(s.model.items.first?.state, .succeeded)
        XCTAssertEqual(s.model.items.first?.result?.files.map(\.url), finished.files.map(\.url))
        XCTAssertEqual(s.api.createdSpecifications.count, 1, "jobs: \(s.api.createdJobIDs)")
        XCTAssertEqual(s.transfers.uploads.count, 1)
    }

    /// Same, with the app's resume already finished when the user taps Retry.
    func testRetryAfterTheAppFinishedItShowsItsResult() async throws {
        let s = try await keptItem()
        s.network.isBack = true
        let resumed = await s.engine.resumePendingConversions()
        let finished = try await XCTUnwrap(resumed.first).result

        s.model.retry(id: s.id)
        try await waitUntilFinished(s.model)

        XCTAssertEqual(s.model.items.first?.state, .succeeded)
        XCTAssertEqual(s.model.items.first?.result?.files.map(\.url), finished.files.map(\.url))
        XCTAssertEqual(s.api.createdSpecifications.count, 1, "jobs: \(s.api.createdJobIDs)")
        XCTAssertEqual(s.transfers.uploads.count, 1)
    }

    /// The user taps Retry the moment the row shows `.failed`, while the
    /// engine is still writing the line that says it kept the conversion.
    func testRetryAsSoonAsTheItemShowsFailedResumesIt() async throws {
        let api = FakeAPI(), transfers = FakeTransfers(), network = DroppedNetwork()
        api.serverHasUpload = { transfers.receivedUploadsSnapshot > 0 }
        api.getJobErrors = [.notConnected]
        let work = TestFiles.temporaryDirectory(), out = TestFiles.temporaryDirectory()
        directories += [work, out]
        var configuration = CloudConvertConfiguration.testing(workingDirectory: work, outputDirectory: out)
        configuration.logger = SlowKeepLogger()
        let engine = ConversionEngine(configuration: configuration, api: api, transfers: transfers, connectivity: network)
        let model = ConversionViewModel(engine: engine)

        model.convert(ConversionRequest.convert(try TestFiles.makeFile(named: "book.epub"), to: "mobi"))
        for _ in 0..<1000 where model.items.first?.state != .failed { try await Task.sleep(nanoseconds: 2_000_000) }
        let id = try XCTUnwrap(model.items.first?.id)
        XCTAssertEqual(model.items.first?.error?.isResumable, true, "the row shows .failed only with its error")

        network.isBack = true
        model.retry(id: id)
        try await waitUntilFinished(model)

        XCTAssertEqual(model.items.map(\.id), [id], "the same conversion, resumed")
        XCTAssertEqual(model.items.first?.state, .succeeded)
        XCTAssertEqual(api.createdSpecifications.count, 1, "retry(id:) converted the file again: jobs \(api.createdJobIDs)")
        XCTAssertEqual(transfers.uploads.count, 1)
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty, "the kept conversion was left behind: \(pending.map(\.id))")
    }
}

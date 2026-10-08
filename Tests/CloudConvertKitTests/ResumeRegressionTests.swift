//  Regressions from the second review of 1.1.0: conversions resumed while
//  something else shows or runs them, uploads judged by the device clock,
//  polling policies that never reach their deadline, cancellations that
//  arrive just as a transfer starts or the network gives up, and export
//  URLs parsed on systems older than iOS 17.
//

import XCTest
@testable import CloudConvertKit
import CloudConvertKitUI

// MARK: - ConversionViewModel: items resumed by retry(id:)

@MainActor
final class ResumedItemTests: XCTestCase {

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

        XCTAssertEqual(model.items.first?.state, .succeeded)
        XCTAssertEqual(api.createdSpecifications.count, 1, "retry(id:) converted the file again: jobs \(api.createdJobIDs)")
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty, "the kept conversion was left behind: \(pending.map(\.id))")
    }
}

// MARK: - Engine

final class ResumeEngineTests: XCTestCase {

    private var api: FakeAPI!
    private var transfers: FakeTransfers!
    private var configuration: CloudConvertConfiguration!
    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        api = FakeAPI()
        transfers = FakeTransfers()
        let work = TestFiles.temporaryDirectory(), out = TestFiles.temporaryDirectory()
        directories = [work, out]
        configuration = .testing(workingDirectory: work, outputDirectory: out)
        let transfers = self.transfers!
        api.serverHasUpload = { transfers.receivedUploadsSnapshot > 0 }
    }

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func makeEngine(connectivity: any ConnectivityMonitoring = AlwaysOnline(),
                            store: (any ConversionRecordStoring)? = nil) -> ConversionEngine {
        ConversionEngine(configuration: configuration, api: api, transfers: transfers, connectivity: connectivity, store: store)
    }

    private func request() throws -> ConversionRequest {
        ConversionRequest.convert(try TestFiles.makeFile(named: "book.epub"), to: "mobi")
    }

    /// Online the whole time; storage is slow, so every upload attempt times
    /// out and nothing arrives. The job is rebuilt with a fresh form, as in
    /// 1.0.1, instead of being kept as if the device were offline.
    func testUploadTimeoutsWhileOnlineRebuildTheJob() async throws {
        transfers.uploadStatuses = [500, 500, 500, 201]
        transfers.lostResponses = 3
        let result = try await makeEngine().convert(try request())

        XCTAssertEqual(result.jobID, "job-2")
        let pending = await makeEngine().pendingConversions()
        XCTAssertTrue(pending.isEmpty)
    }

    /// Resuming after a relaunch: the previous launch's upload reaches
    /// storage and only its response is lost, and by the device clock the
    /// form has expired. The job that has the file converts it.
    func testReattachedUploadThatArrivedKeepsTheJobAlthoughTheFormLooksExpired() async throws {
        let arrived = Flag()
        api.serverHasUpload = { arrived.isSet }
        try await seedPreviousLaunch(phase: .uploading, configuration: configuration, api: api) {
            $0.uploadTransfers = ["import-1": "upload-from-last-launch"]
        }
        api.formExpiresIn = -3600
        api.jobStatusScript = [.waiting, .processing, .finished]
        transfers.reattach = { _ in
            arrived.set()
            throw CloudConvertError.network(code: .networkConnectionLost, description: "lost")
        }

        let handles = await makeEngine().resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-9")
        XCTAssertTrue(api.createdSpecifications.isEmpty, "a second job \(api.createdJobIDs) converts and bills the file again")
        XCTAssertTrue(transfers.uploads.isEmpty)
    }

    /// Same, with nothing delivered: the expired form rebuilds the job.
    func testReattachedUploadThatDidNotArriveRebuildsAnExpiredForm() async throws {
        try await seedPreviousLaunch(phase: .uploading, configuration: configuration, api: api) {
            $0.uploadTransfers = ["import-1": "upload-from-last-launch"]
        }
        api.formExpiresIn = -3600
        api.jobStatusScript = [.waiting, .waiting, .processing, .finished]     // job-9 still offers its form when checked
        transfers.reattach = { _ in throw CloudConvertError.network(code: .networkConnectionLost, description: "lost") }

        let handles = await makeEngine().resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-1")
        XCTAssertEqual(transfers.uploads.count, 1)
        for _ in 0..<100 where !api.deletedJobIDsSnapshot.contains("job-9") { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(api.deletedJobIDsSnapshot.contains("job-9"), "the job without the file is deleted")
    }

    /// `initialInterval: 0` and a multiplier below 1 would never add up to
    /// `jobTimeout`; the deadline is still reached.
    func testPollingReachesTheDeadlineWithAZeroOrShrinkingInterval() async throws {
        for policy in [PollingPolicy(initialInterval: 0, maxInterval: 1, multiplier: 2, jobTimeout: 0.2, maxConsecutiveFailures: 3),
                       PollingPolicy(initialInterval: 0.01, maxInterval: 1, multiplier: 0.5, jobTimeout: 0.1, maxConsecutiveFailures: 3),
                       PollingPolicy(initialInterval: 0, maxInterval: 0, multiplier: .nan, jobTimeout: 0.1, maxConsecutiveFailures: 3)] {
            configuration.polling = policy
            api.jobStatusScript = [.processing]
            let engine = makeEngine(), conversionRequest = try request()

            let conversion = Task { try await engine.convert(conversionRequest) }
            let watchdog = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); conversion.cancel() }
            let outcome = await conversion.result
            watchdog.cancel()

            guard case .failure(let error) = outcome, case .jobTimedOut = error as? CloudConvertError else {
                return XCTFail("\(policy): \(outcome)")
            }
            for record in await engine.pendingConversions() { await engine.discardPendingConversion(id: record.id) }
        }
    }

    /// The user cancels while a status check finds the device offline, and
    /// the wait for the network then gives up: a cancellation, not kept.
    func testCancellingDuringAnOfflinePollIsACancellation() async throws {
        let engine = makeEngine(connectivity: DroppedNetwork())
        let handleBox = HandleBox(), calls = Counter()
        api.getJobHook = { _ in
            if calls.next() == 1 {
                handleBox.handle?.cancel()
                throw CloudConvertError.notConnected
            }
        }
        let handle = engine.start(try request())
        handleBox.handle = handle

        do {
            _ = try await handle.result
            XCTFail("expected an error")
        } catch let error as CloudConvertError {
            XCTAssertTrue(error.isCancellation, "cancelled by the user, ended with \(error)")
        }
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty, "a conversion the user cancelled was kept: \(pending.map(\.id))")
    }

    /// `resumedConversion(id:)` follows a resume while it runs and after it
    /// succeeds, without running it twice.
    func testResumedConversionFollowsAResume() async throws {
        try await seedPreviousLaunch(phase: .processing, configuration: configuration, api: api)
        let gate = Gate()
        api.getJobHook = { _ in try await gate.wait() }
        let engine = makeEngine()

        let handles = await engine.resumePendingConversions()
        let first = try XCTUnwrap(handles.first)
        let joined = try XCTUnwrap(engine.resumedConversion(id: first.id))
        let again = await engine.resumePendingConversions()
        XCTAssertTrue(again.isEmpty, "running, so not resumed twice")
        gate.open()

        let result = try await first.result
        let joinedResult = try await joined.result
        XCTAssertEqual(joinedResult.files.map(\.url), result.files.map(\.url))
        var stages: [ConversionProgress.Stage] = []
        for await progress in joined.progress { stages.append(progress.stage) }
        XCTAssertEqual(stages.last, .completed)

        let later = try XCTUnwrap(engine.resumedConversion(id: first.id), "a resume that succeeded is still followed")
        let laterResult = try await later.result
        XCTAssertEqual(laterResult.files.map(\.url), result.files.map(\.url))
        XCTAssertNil(engine.resumedConversion(id: "unknown"))
        XCTAssertTrue(api.createdSpecifications.isEmpty)
    }

    /// One that fails for good is not followed: trying it again starts over.
    func testResumedConversionIsDroppedWhenItFails() async throws {
        try await seedPreviousLaunch(phase: .processing, configuration: configuration, api: api)
        api.jobStatusScript = [.error]
        api.failureCode = "INVALID_CONVERSION_TYPE"
        let engine = makeEngine()

        let handles = await engine.resumePendingConversions()
        let handle = try XCTUnwrap(handles.first)
        do {
            _ = try await handle.result
            XCTFail("expected the job's failure")
        } catch let error as CloudConvertError {
            guard case .jobFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(engine.resumedConversion(id: handle.id))
    }

    /// One that stops again with a resumable error is pending again, and
    /// what followed it sees that error.
    func testResumedConversionThatIsKeptAgainIsPending() async throws {
        try await seedPreviousLaunch(phase: .processing, configuration: configuration, api: api)
        api.getJobErrors = [.notConnected]
        let engine = makeEngine(connectivity: DroppedNetwork())

        let handles = await engine.resumePendingConversions()
        let handle = try XCTUnwrap(handles.first)
        do {
            _ = try await handle.result
            XCTFail("expected the conversion to be kept")
        } catch let error as CloudConvertError {
            XCTAssertTrue(error.isResumable, "\(error)")
        }
        let pending = await engine.pendingConversions()
        XCTAssertEqual(pending.map(\.id), [handle.id])
        let followed = try XCTUnwrap(engine.resumedConversion(id: handle.id))
        do {
            _ = try await followed.result
            XCTFail("expected the error the resume stopped with")
        } catch let error as CloudConvertError {
            XCTAssertTrue(error.isResumable, "\(error)")
        }
        await engine.discardPendingConversion(id: handle.id)
        XCTAssertNil(engine.resumedConversion(id: handle.id), "discarded")
    }

    /// A record listed as pending but finished by the time it is claimed (its
    /// record deleted) is not run again from the stale copy.
    func testARecordThatFinishedBeforeItIsClaimedIsNotRun() async throws {
        let record = try await seedPreviousLaunch(phase: .processing, configuration: configuration, api: api)
        let engine = makeEngine(store: StaleListStore(listed: [record]))

        let handles = await engine.resumePendingConversions()

        XCTAssertTrue(handles.isEmpty)
        XCTAssertEqual(api.pollCount, 0)
        XCTAssertTrue(api.createdSpecifications.isEmpty)
    }

    // MARK: Kept conversions resume from every phase

    private func keptThenResumed(failUploads: Bool, failDownloads: Bool) async throws -> (phase: ConversionPhase, result: ConversionResult) {
        let network = DroppedNetwork()
        let offline = OfflineUntilBackTransfers(inner: transfers, network: network, failUploads: failUploads, failDownloads: failDownloads)
        let engine = ConversionEngine(configuration: configuration, api: api, transfers: offline, connectivity: network)
        let handle = engine.start(try request())
        do {
            _ = try await handle.result
            XCTFail("expected the conversion to be kept")
        } catch let error as CloudConvertError {
            XCTAssertTrue(error.isResumable, "\(error)")
        }
        let pending = await engine.pendingConversions()
        XCTAssertEqual(pending.map(\.id), [handle.id])
        let phase = try XCTUnwrap(pending.first?.phase)
        network.isBack = true
        let resumed = await engine.resumePendingConversions(where: { $0.id == handle.id })
        let result = try await XCTUnwrap(resumed.first).result
        let left = await engine.pendingConversions()
        XCTAssertTrue(left.isEmpty)
        return (phase, result)
    }

    func testKeptDuringUploadResumesWithTheSameJob() async throws {
        api.jobStatusScript = [.waiting, .processing, .finished]
        let (phase, result) = try await keptThenResumed(failUploads: true, failDownloads: false)
        XCTAssertEqual(phase, .uploading)
        XCTAssertEqual(result.jobID, "job-1")
        XCTAssertEqual(api.createdSpecifications.count, 1)
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    func testKeptDuringDownloadResumesWithoutPollingAgain() async throws {
        let (phase, result) = try await keptThenResumed(failUploads: false, failDownloads: true)
        XCTAssertEqual(phase, .downloading)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(api.createdSpecifications.count, 1)
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    func testKeptWhileCreatingTheJobResumes() async throws {
        try await seedPreviousLaunch(phase: .creatingJob, configuration: configuration, api: api)
        let network = DroppedNetwork()
        api.getJobErrors = [.notConnected]
        api.jobStatusScript = [.waiting, .processing, .finished]
        let engine = makeEngine(connectivity: network)
        let first = await engine.resumePendingConversions()
        do {
            _ = try await XCTUnwrap(first.first).result
            XCTFail("expected the conversion to be kept")
        } catch let error as CloudConvertError {
            XCTAssertTrue(error.isResumable, "\(error)")
        }
        let pending = await engine.pendingConversions()
        XCTAssertEqual(pending.map(\.phase), [.creatingJob])
        network.isBack = true
        let again = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(again.first).result
        XCTAssertEqual(result.jobID, "job-9")
        XCTAssertTrue(api.createdSpecifications.isEmpty)
    }

    func testConcurrentResumesRunAKeptRecordOnce() async throws {
        try await seedPreviousLaunch(phase: .processing, configuration: configuration, api: api)
        let gate = Gate()
        api.getJobHook = { _ in try await gate.wait() }
        let engine = makeEngine()
        async let a = engine.resumePendingConversions()
        async let b = engine.resumePendingConversions()
        async let c = engine.resumePendingConversions(where: { _ in true })
        let handles = await a + b + c
        XCTAssertEqual(handles.count, 1)
        let pendingWhileRunning = await engine.pendingConversions()
        XCTAssertTrue(pendingWhileRunning.isEmpty, "a running conversion is not pending")
        gate.open()
        _ = try await handles.first?.result
    }

    /// A multi-file conversion kept after saving its first output: discarding
    /// it removes that output, the record and the job.
    func testDiscardingAKeptMultiFileConversionRemovesSavedOutputs() async throws {
        api.exportFiles = [(filename: "page-1.jpg", size: 9, url: "https://storage.example/1"),
                           (filename: "page-2.jpg", size: 9, url: "https://storage.example/2")]
        final class SecondDownloadOffline: FileTransferring, @unchecked Sendable {
            let inner: FakeTransfers, downloads = Counter()
            init(_ inner: FakeTransfers) { self.inner = inner }
            func upload(id: String, request: URLRequest, bodyFile: URL,
                        progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
                try await inner.upload(id: id, request: request, bodyFile: bodyFile, progress: progress)
            }
            func download(id: String, request: URLRequest, destination: URL,
                          progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
                if downloads.next() > 1 { throw CloudConvertError.notConnected }
                return try await inner.download(id: id, request: request, destination: destination, progress: progress)
            }
            func awaitExistingTransfer(id: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
                try await inner.awaitExistingTransfer(id: id, progress: progress)
            }
            func cancel(id: String) {}
            func forget(id: String) {}
        }
        let engine = ConversionEngine(configuration: configuration, api: api, transfers: SecondDownloadOffline(transfers),
                                      connectivity: DroppedNetwork())
        let handle = engine.start(ConversionRequest.convert(try TestFiles.makeFile(named: "scan.pdf"), to: "jpg"))
        do {
            _ = try await handle.result
            XCTFail("expected the conversion to be kept")
        } catch let error as CloudConvertError {
            XCTAssertTrue(error.isResumable, "\(error)")
        }
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: configuration.outputDirectory.path)) ?? []
        XCTAssertEqual(saved.count, 1, "the first page was saved before the network went")

        await engine.discardPendingConversion(id: handle.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: configuration.outputDirectory.path)) ?? []
        XCTAssertTrue(left.isEmpty, "left: \(left)")
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-1"])
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty)
    }
}

// MARK: - BackgroundTransferManager

final class TransferCancellationTests: XCTestCase {

    /// Upload tasks whose completion is delivered the moment they are
    /// cancelled: the delegate finishes the transfer before its waiter
    /// has installed its continuation.
    final class InstantCancelSession: URLSession, @unchecked Sendable {
        weak var manager: BackgroundTransferManager?
        override func uploadTask(with request: URLRequest, fromFile fileURL: URL) -> URLSessionUploadTask {
            let task = InstantCancelTask()
            task.onCancel = { [weak self] cancelled in
                guard let self, let manager = self.manager else { return }
                manager.urlSession(self, task: cancelled, didCompleteWithError: URLError(.cancelled))
            }
            return task
        }
    }

    final class InstantCancelTask: URLSessionUploadTask, @unchecked Sendable {
        var onCancel: ((URLSessionTask) -> Void)?
        private var storedDescription: String?
        override var taskDescription: String? {
            get { storedDescription }
            set { storedDescription = newValue }
        }
        override var response: URLResponse? { nil }
        override func resume() {}
        override func cancel() { onCancel?(self) }
    }

    func testCancellationJustAsATransferStartsIsACancellation() async throws {
        let manager = BackgroundTransferManager(identifier: "tests.\(UUID().uuidString)",
                                                registryDirectory: TestFiles.temporaryDirectory(),
                                                usesBackgroundSession: false,
                                                logger: SilentCloudConvertLogger())
        let session = InstantCancelSession()
        session.manager = manager
        manager.session = session
        let body = try TestFiles.makeFile(named: "body.bin")
        var request = URLRequest(url: URL(string: "https://upload.example/form")!)
        request.httpMethod = "POST"

        let waiter = Task { () async throws -> TransferOutcome in
            withUnsafeCurrentTask { $0?.cancel() }        // the caller is cancelled just as the upload starts
            return try await manager.upload(id: "upload-1", request: request, bodyFile: body) { _ in }
        }

        do {
            _ = try await waiter.value
            XCTFail("expected an error")
        } catch CloudConvertError.cancelled {
        } catch {
            XCTFail("a cancellation the caller asked for came back as \(error)")
        }
    }
}

// MARK: - Export URLs on systems before iOS 17

final class LenientURLTests: XCTestCase {

    /// The encoding `URL(lenient:)` falls back to parses with the strict,
    /// pre-iOS 17 rules, into the URL iOS 17 makes of the raw string.
    func testEncodedExportURLsParseStrictly() throws {
        guard #available(macOS 14, iOS 17, *) else { throw XCTSkip("needs URL(string:encodingInvalidCharacters:)") }
        let raws = [
            "https://storage.cloudconvert.com/tasks/abc/My File (1).pdf?AWSAccessKeyId=X&Expires=1&Signature=a%2Fb%3D",
            "https://s.example/ü ñ.pdf",
            "https://s.example/a\"b<c>.pdf",
            "https://s.example/a{b}^c`d.pdf",
            "https://s.example/100%.pdf",
            "https://s.example/a%2.pdf?x=%zz",
            "https://s.example/a b.pdf#frag ment",
            "https://s.example/a#b#c.pdf",
            "https://user:p w@s.example/a.pdf",
        ]
        for raw in raws {
            let strict = URL(string: URL.encodingInvalidCharacters(raw), encodingInvalidCharacters: false)
            XCTAssertNotNil(strict, raw)
            XCTAssertEqual(strict?.absoluteString, URL(string: raw)?.absoluteString, raw)
        }
    }
}

// MARK: - Helpers

final class HandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConversionHandle?
    var handle: ConversionHandle? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// A logger that takes a while to write the line `stop` writes after
/// reporting `.failed` for a kept conversion (a file, analytics…).
final class SlowKeepLogger: CloudConvertLogging, @unchecked Sendable {
    func log(_ level: LogLevel, _ message: @autoclosure () -> String, metadata: [String: String]) {
        if message().contains("to resume") { Thread.sleep(forTimeInterval: 0.5) }
    }
}

/// The engine's record store, with `all()` held while `hold()` is in effect.
final class HeldStore: ConversionRecordStoring, @unchecked Sendable {
    private let inner: ConversionRecordStore
    private let gate = Gate()
    private let holding = Flag(), held = Flag()

    init(directory: URL) { inner = ConversionRecordStore(directory: directory, logger: SilentCloudConvertLogger()) }

    func hold() { holding.set() }
    func release() { gate.open() }
    /// Whether a call to `all()` is waiting for `release()`.
    var isHolding: Bool { held.isSet }

    func save(_ record: ConversionRecord) async { await inner.save(record) }
    func load(id: String) async -> ConversionRecord? { await inner.load(id: id) }
    func delete(id: String) async { await inner.delete(id: id) }
    func all() async -> [ConversionRecord] {
        if holding.isSet {
            held.set()
            try? await gate.wait()
        }
        return await inner.all()
    }
}

/// A store whose list still shows records that are gone.
final class StaleListStore: ConversionRecordStoring, @unchecked Sendable {
    private let listed: [ConversionRecord]
    init(listed: [ConversionRecord]) { self.listed = listed }
    func save(_ record: ConversionRecord) async {}
    func load(id: String) async -> ConversionRecord? { nil }
    func delete(id: String) async {}
    func all() async -> [ConversionRecord] { listed }
}

/// Fails uploads and/or downloads with `.notConnected` until the network is back.
final class OfflineUntilBackTransfers: FileTransferring, @unchecked Sendable {
    let inner: FakeTransfers
    let network: DroppedNetwork
    let failUploads: Bool
    let failDownloads: Bool

    init(inner: FakeTransfers, network: DroppedNetwork, failUploads: Bool, failDownloads: Bool) {
        self.inner = inner; self.network = network; self.failUploads = failUploads; self.failDownloads = failDownloads
    }

    func upload(id: String, request: URLRequest, bodyFile: URL,
                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        if failUploads, !network.isBack { throw CloudConvertError.notConnected }
        return try await inner.upload(id: id, request: request, bodyFile: bodyFile, progress: progress)
    }

    func download(id: String, request: URLRequest, destination: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        if failDownloads, !network.isBack { throw CloudConvertError.notConnected }
        return try await inner.download(id: id, request: request, destination: destination, progress: progress)
    }

    func awaitExistingTransfer(id: String, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferOutcome {
        try await inner.awaitExistingTransfer(id: id, progress: progress)
    }

    func cancel(id: String) { inner.cancel(id: id) }
    func forget(id: String) { inner.forget(id: id) }
}

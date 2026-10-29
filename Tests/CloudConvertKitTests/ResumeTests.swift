//  Conversions kept when the network or the polling deadline runs out, and
//  resumed later.
//

import XCTest
import Network
@testable import CloudConvertKit
import CloudConvertKitUI

// MARK: - Interruptions

final class InterruptionTests: XCTestCase {

    private var api: FakeAPI!
    private var transfers: FakeTransfers!
    private var configuration: CloudConvertConfiguration!
    private var engine: ConversionEngine!
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
        engine = makeEngine()
    }

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func makeEngine(connectivity: any ConnectivityMonitoring = AlwaysOnline()) -> ConversionEngine {
        ConversionEngine(configuration: configuration, api: api, transfers: transfers, connectivity: connectivity)
    }

    private func request() throws -> ConversionRequest {
        ConversionRequest.convert(try TestFiles.makeFile(named: "book.epub"), to: "mobi")
    }

    /// #2: the network goes for longer than the wait once the job exists.
    /// The job may finish, and be billed, so it is kept; resuming when the
    /// network is back finishes it without a second job or upload.
    func testLosingTheNetworkAfterUploadKeepsTheConversion() async throws {
        let network = DroppedNetwork()
        engine = makeEngine(connectivity: network)
        api.getJobErrors = [.notConnected]          // the first poll finds the device offline
        let log = StageLog()

        let handle = engine.start(try request())
        let observer = Task { for await progress in handle.progress { log.append(progress.stage) } }
        do {
            _ = try await handle.result
            XCTFail("expected an interruption")
        } catch let error as CloudConvertError {
            guard case .timedOut(phase: .waitingForNetwork) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(error.isResumable)
            XCTAssertTrue(error.isConnectivityRelated, "the app shows an offline banner")
            XCTAssertFalse(error.isRetryable, "starting it again would convert the file twice")
        }
        await observer.value
        XCTAssertEqual(log.snapshot.filter(\.isTerminal), [.failed])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(api.deletedJobIDsSnapshot.isEmpty, "the job may still finish")
        let pending = await engine.pendingConversions()
        XCTAssertEqual(pending.map(\.id), [handle.id])

        network.isBack = true
        let resumed = await engine.resumePendingConversions()
        XCTAssertEqual(resumed.map(\.id), [handle.id])
        let result = try await XCTUnwrap(resumed.first).result
        XCTAssertEqual(result.jobID, "job-1")
        XCTAssertEqual(api.createdSpecifications.count, 1, "no second job")
        XCTAssertEqual(transfers.uploads.count, 1, "no second upload")
        await waitUntil { self.api.deletedJobIDsSnapshot == ["job-1"] }
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-1"])
        let left = await engine.pendingConversions()
        XCTAssertTrue(left.isEmpty)
    }

    /// #2: resuming at launch while offline keeps the conversion pending.
    func testResumingWhileOfflineKeepsThePendingConversion() async throws {
        let record = try await seedPreviousLaunch(phase: .processing, configuration: configuration, api: api)
        engine = makeEngine(connectivity: DroppedNetwork())
        api.getJobErrors = [.notConnected]

        let handles = await engine.resumePendingConversions()
        do {
            _ = try await XCTUnwrap(handles.first).result
            XCTFail("expected an interruption")
        } catch let error as CloudConvertError {
            XCTAssertTrue(error.isResumable, "unexpected \(error)")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(api.deletedJobIDsSnapshot.isEmpty)
        let pending = await engine.pendingConversions()
        XCTAssertEqual(pending.map(\.id), [record.id])
        XCTAssertTrue(record.staged.values.allSatisfy { FileManager.default.fileExists(atPath: $0.stagedURL.path) })
    }

    /// #1: a poll that took longer than the whole deadline (the app was
    /// suspended mid-request) does not count against it, and the job that
    /// finished meanwhile is picked up instead of deleted.
    func testTimeTheAppSpentSuspendedDoesNotCountTowardsTheDeadline() async throws {
        configuration.polling.jobTimeout = 0.05
        engine = makeEngine()
        let polls = Counter()
        api.getJobHook = { _ in if polls.next() == 1 { try await Task.sleep(nanoseconds: 150_000_000) } }

        let result = try await engine.convert(try request())

        XCTAssertEqual(result.jobID, "job-1")
        XCTAssertEqual(api.createdSpecifications.count, 1)
    }

    /// #1: when the deadline passes with the job still running, the job is
    /// kept, not deleted, and resuming later picks it up.
    func testPollingDeadlineKeepsAJobThatIsStillRunning() async throws {
        configuration.polling.jobTimeout = 0.05
        engine = makeEngine()
        api.jobStatusScript = [.processing]

        let handle = engine.start(try request())
        do {
            _ = try await handle.result
            XCTFail("expected an interruption")
        } catch let error as CloudConvertError {
            guard case .jobTimedOut = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(error.isResumable)
            XCTAssertFalse(error.isConnectivityRelated)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(api.deletedJobIDsSnapshot.isEmpty, "a job that may still finish is not deleted")

        api.jobStatusScript = [.finished]
        let resumed = await engine.resumePendingConversions(where: { $0.id == handle.id })
        let result = try await XCTUnwrap(resumed.first).result
        XCTAssertEqual(result.jobID, "job-1")
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    /// Only the two errors a kept conversion ends with are resumable.
    func testOnlyTheErrorsOfAKeptConversionAreResumable() {
        let offline = CloudConvertError.timedOut(phase: .waitingForNetwork)
        XCTAssertTrue(offline.isResumable)
        XCTAssertTrue(offline.isConnectivityRelated)
        XCTAssertFalse(offline.isRetryable)
        XCTAssertTrue(CloudConvertError.jobTimedOut(jobID: "j").isResumable)
        for error: CloudConvertError in [.notConnected, .timedOut(phase: .processing), .network(code: .networkConnectionLost, description: ""),
                                         .jobLost(jobID: "j"), .cancelled] {
            XCTAssertFalse(error.isResumable, "\(error)")
        }
        XCTAssertTrue(CloudConvertError.timedOut(phase: .processing).isRetryable)
        XCTAssertFalse(CloudConvertError.timedOut(phase: .processing).isConnectivityRelated)
    }

    /// `resumePendingConversions(where:)` starts only the records it accepts
    /// and leaves the others exactly as they were.
    func testResumingSelectedConversionsLeavesTheOthersAlone() async throws {
        _ = try await seedPreviousLaunch(id: "mine", phase: .processing, jobID: "job-9", configuration: configuration, api: api)
        _ = try await seedPreviousLaunch(id: "other", phase: .processing, jobID: "job-10", configuration: configuration, api: api)
        let other = await engine.pendingConversions().filter { $0.id == "other" }

        let handles = await engine.resumePendingConversions(where: { $0.id == "mine" })

        XCTAssertEqual(handles.map(\.id), ["mine"])
        let pendingWhileRunning = await engine.pendingConversions()
        XCTAssertEqual(pendingWhileRunning.map(\.id), ["other"], "the other record is not marked as running")
        _ = try await XCTUnwrap(handles.first).result
        let pending = await engine.pendingConversions()
        XCTAssertEqual(pending, other, "the other record is untouched")
        XCTAssertFalse(api.polledJobIDs.contains("job-10"), "the other conversion was not started")
    }
}

// MARK: - Resuming

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
    /// out and nothing arrives. The job is rebuilt with a fresh form instead
    /// of being kept as if the device were offline.
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
        for policy in [PollingPolicy(initialInterval: 0, maxInterval: 1, multiplier: 2, jobTimeout: 0.05, maxConsecutiveFailures: 3),
                       PollingPolicy(initialInterval: 0.01, maxInterval: 1, multiplier: 0.5, jobTimeout: 0.05, maxConsecutiveFailures: 3),
                       PollingPolicy(initialInterval: 0, maxInterval: 0, multiplier: .nan, jobTimeout: 0.05, maxConsecutiveFailures: 3)] {
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
        api.taskCredits = 2
        let (phase, result) = try await keptThenResumed(failUploads: false, failDownloads: true)
        XCTAssertEqual(phase, .downloading)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.credits, 2, "the credits the job reported before the pause")
        XCTAssertEqual(api.createdSpecifications.count, 1)
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    /// Records written before `key`, `credits` and `formatVersion` existed
    /// (as `seedPreviousLaunch` writes them) still decode and resume.
    func testARecordWithoutTheNewerFieldsResumes() async throws {
        let record = try await seedPreviousLaunch(phase: .processing, configuration: configuration, api: api)
        let file = FileStorage(workingDirectory: configuration.workingDirectory, outputDirectory: configuration.outputDirectory,
                               diskSpaceSafetyMargin: 0).recordsDirectory.appendingPathComponent("\(record.id).json")
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(json.contains("formatVersion") || json.contains("\"key\"") || json.contains("\"credits\""))

        let handles = await makeEngine().resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result
        XCTAssertEqual(result.jobID, "job-9")
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

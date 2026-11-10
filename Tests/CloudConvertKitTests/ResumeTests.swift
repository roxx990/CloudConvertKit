//  Conversions kept when the network or the polling deadline runs out, and
//  resumed later: in this process, after a relaunch, from every phase.
//

import XCTest
import Network
@testable import CloudConvertKit

// MARK: - Interruptions

final class InterruptionTests: EngineTestCase {

    // MARK: Offline

    func testOfflineTimeoutFailsOnceWithoutRebuildingJob() async throws {
        engine = makeEngine(connectivity: AlwaysOffline())
        let log = StageLog()

        do {
            _ = try await engine.convert(try request()) { log.append($0.stage) }
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .notConnected = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(error.isRetryable, "the app may offer Try again")
            XCTAssertTrue(error.isConnectivityRelated, "the app should show an offline banner")
        }
        XCTAssertTrue(api.createdSpecifications.isEmpty, "nothing is sent while offline")
        XCTAssertTrue(log.snapshot.contains(.waitingForNetwork))
        XCTAssertEqual(log.snapshot.filter { $0 == .failed }.count, 1, "exactly one terminal stage")
        XCTAssertEqual(log.snapshot.last, .failed)
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testATransferReportsWaitingForNetworkWhileOffline() async throws {
        transfers.uploadDelay = 0.2
        let network = FakeConnectivity()
        let engine = makeEngine(connectivity: network)
        let log = StageLog()
        let request = try request()
        let task = Task { try await engine.convert(request) { log.append($0.stage) } }
        await waitUntil { log.snapshot.contains(.uploading) }
        network.isConnected = false
        await waitUntil { log.snapshot.contains(.waitingForNetwork) }
        network.isConnected = true
        _ = try await task.value
        let stages = log.snapshot
        let offline = try XCTUnwrap(stages.firstIndex(of: .waitingForNetwork))
        XCTAssertTrue(stages[(offline + 1)...].contains(.uploading))
    }

    /// The network goes for longer than the wait once the job exists.
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

    /// Resuming at launch while offline keeps the conversion pending.
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

    func testAConversionKeptOfflineContinuesWhenTheNetworkReturns() async throws {
        configuration.resumesWhenOnline = true
        configuration.offlineWaitTimeout = 0.1
        let network = FakeConnectivity()
        let engine = makeEngine(connectivity: network)
        let resumes = engine.automaticResumes()
        api.getJobHook = { [api] _ in
            if network.isConnected, api!.pollCount == 0 {
                network.isConnected = false
                api!.getJobErrors = [.notConnected]
            }
        }

        do {
            _ = try await engine.convert(try request())
            XCTFail("expected the conversion to pause")
        } catch let error as CloudConvertError {
            XCTAssertEqual(error.category, .paused)
        }
        api.getJobHook = nil
        network.isConnected = true

        // Bounded: if nothing resumes, the test fails instead of hanging the suite.
        let handle = try await XCTUnwrapAsync(await withTimeout(seconds: 5) { await resumes.first { _ in true } } ?? nil,
                                              "nothing resumed when the network came back")
        let result = try await handle.result
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(api.createdJobIDs.count, 1)
    }

    // MARK: The polling deadline

    /// A poll that took longer than the whole deadline (the app was
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

    /// When the deadline passes with the job still running, the job is
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
}

// MARK: - Resuming

final class ResumeTests: EngineTestCase {

    func testRunningConversionIsNotReportedAsPending() async throws {
        transfers.uploadDelay = 0.2
        let handle = engine.start(try request())
        await waitUntil { !self.transfers.uploads.isEmpty }

        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty, "a conversion running in this process is not pending")
        let resumed = await engine.resumePendingConversions()
        XCTAssertTrue(resumed.isEmpty, "and must not be started a second time")

        _ = try await handle.result
        XCTAssertEqual(api.createdSpecifications.count, 1)
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    /// A conversion a previous launch left while the server converted it
    /// continues with its job and its `userInfo`: nothing is uploaded or
    /// created again, and the job is deleted once the output is saved.
    func testAKeptConversionContinuesWithItsJob() async throws {
        try await seedPreviousLaunch(phase: .processing, configuration: configuration, api: api) {
            $0.userInfo = ["historyRow": "7"]
        }
        api.jobStatusScript = [.processing, .finished]

        let handles = await engine.resumePendingConversions()
        XCTAssertEqual(handles.count, 1)
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-9")
        XCTAssertEqual(result.userInfo["historyRow"], "7")
        XCTAssertEqual(result.files.count, 1)
        XCTAssertTrue(transfers.uploads.isEmpty, "the upload had already completed; it must not be repeated")
        XCTAssertTrue(api.createdSpecifications.isEmpty, "the existing job is reused, not recreated")
        await waitUntil { self.api.deletedJobIDsSnapshot == ["job-9"] }
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-9"])
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty)
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

    /// A record without the optional `key`, `credits` and `formatVersion`
    /// (as `seedPreviousLaunch` writes it) decodes and resumes.
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

    // MARK: Following a resume

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

    // MARK: Kept in every phase

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

    // MARK: Discarding

    func testDiscardWhereLeavesTheOthers() async throws {
        configuration.polling.jobTimeout = 0.05
        api.jobStatusScript = [.processing]
        let engine = makeEngine()
        _ = try? await engine.convert(try request("a.docx", key: "a"))
        _ = try? await engine.convert(try request("b.docx", key: "b"))
        await engine.discardPendingConversions { $0.key == "a" }
        let left = await engine.pendingConversions().map(\.key)
        XCTAssertEqual(left, ["b"])
    }

    /// Discarding a conversion that is running is refused.
    func testDiscardingARunningConversionIsRefused() async throws {
        transfers.uploadDelay = 0.3
        let handle = engine.start(try request())
        await waitUntil { !self.transfers.uploads.isEmpty }
        await engine.discardPendingConversion(id: handle.id)
        _ = try await handle.result
        XCTAssertTrue(transfers.cancelled.isEmpty)
    }

    /// A multi-file conversion kept after saving its first output: discarding
    /// it removes that output, the record and the job.
    func testDiscardingAKeptMultiFileConversionRemovesSavedOutputs() async throws {
        api.exportFiles = [(filename: "page-1.jpg", size: 9, url: "https://storage.example/1"),
                           (filename: "page-2.jpg", size: 9, url: "https://storage.example/2")]
        final class SecondDownloadOffline: FileTransferring, @unchecked Sendable {
            let inner: FakeFileTransfers, downloads = Counter()
            init(_ inner: FakeFileTransfers) { self.inner = inner }
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

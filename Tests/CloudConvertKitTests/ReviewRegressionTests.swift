//  Regression tests for the issues an independent review of 1.0.1 found
//  (1.1.0). A conversion whose job may still finish is kept, not deleted,
//  when the network or the polling deadline runs out; transfers re-attached
//  after a relaunch are retried like fresh ones; nothing the server sends
//  can trap.
//

import XCTest
import Network
@testable import CloudConvertKit

// MARK: - Keeping conversions whose job may still finish (#1, #2)

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
        configuration.polling.jobTimeout = 0.2
        engine = makeEngine()
        let polls = Counter()
        api.getJobHook = { _ in if polls.next() == 1 { try await Task.sleep(nanoseconds: 500_000_000) } }

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

// MARK: - Transfers re-attached after a relaunch (#3, #13)

final class ReattachTests: XCTestCase {

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
        engine = ConversionEngine(configuration: configuration, api: api, transfers: transfers, connectivity: AlwaysOnline())
    }

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    /// The app died mid-upload; the upload of `import-1` was still running.
    private func seedInterruptedUpload() async throws {
        _ = try await seedPreviousLaunch(phase: .uploading, configuration: configuration, api: api) {
            $0.uploadTransfers = ["import-1": "upload-from-last-launch"]
        }
    }

    /// #3: a re-attached upload that storage answered with a 503 is retried
    /// against the same form, as a fresh one is, instead of rebuilding the job.
    func testReattachedUploadAnswered503IsRetriedAgainstTheSameForm() async throws {
        try await seedInterruptedUpload()
        transfers.reattach = { _ in outcome(503) }
        api.jobStatusScript = [.waiting, .waiting, .processing, .finished]

        let handles = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-9")
        XCTAssertTrue(api.createdSpecifications.isEmpty, "the job is not rebuilt")
        XCTAssertEqual(transfers.reattached, ["upload-from-last-launch"])
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    /// #3: a re-attached upload whose connection dropped waits for the
    /// network and is retried, instead of failing the conversion.
    func testReattachedUploadThatLostTheNetworkIsRetried() async throws {
        try await seedInterruptedUpload()
        transfers.reattach = { _ in throw CloudConvertError.network(code: .networkConnectionLost, description: "lost") }
        api.jobStatusScript = [.waiting, .waiting, .processing, .finished]

        let handles = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-9")
        XCTAssertTrue(api.createdSpecifications.isEmpty)
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    /// #3: a re-attached download answered with a 503 is retried like a
    /// fresh one; the paid job is neither failed nor deleted.
    func testReattachedDownloadAnswered503IsRetried() async throws {
        let file = CCExportedFile(filename: "book.mobi", size: 9, url: URL(string: "https://storage.example/book.mobi")!)
        _ = try await seedPreviousLaunch(phase: .downloading, configuration: configuration, api: api) {
            $0.exportedFiles = [ExportedFileRecord(file)]
            $0.downloadTransfers = [0: "download-from-last-launch"]
        }
        transfers.reattach = { _ in outcome(503) }

        let handles = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.files.map(\.filename), ["book.mobi"])
        XCTAssertEqual(transfers.reattached, ["download-from-last-launch"])
        XCTAssertEqual(transfers.downloads.count, 1)
        await waitUntil { self.api.deletedJobIDsSnapshot == ["job-9"] }
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-9"], "deleted once the output is saved, not before")
    }

    /// #13: a re-attached upload that succeeded while the app was away is
    /// not sent again.
    func testReattachedUploadThatSucceededIsNotSentAgain() async throws {
        try await seedInterruptedUpload()
        transfers.reattach = { _ in outcome(201) }
        api.jobStatusScript = [.waiting, .processing, .finished]

        let handles = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-9")
        XCTAssertTrue(transfers.uploads.isEmpty)
    }

    /// #13: cancelling while waiting on a re-attached transfer cancels the
    /// conversion and cleans up.
    func testCancellingWhileWaitingOnAReattachedTransfer() async throws {
        try await seedInterruptedUpload()
        let gate = Gate()
        transfers.reattach = { _ in try await gate.wait(); return outcome(201) }

        let handles = await engine.resumePendingConversions()
        let handle = try XCTUnwrap(handles.first)
        await waitUntil { !self.transfers.reattached.isEmpty }
        handle.cancel()

        do {
            _ = try await handle.result
            XCTFail("expected cancellation")
        } catch let error as CloudConvertError {
            guard case .cancelled = error else { return XCTFail("unexpected \(error)") }
        }
        await waitUntil { !self.api.deletedJobIDsSnapshot.isEmpty }
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-9"])
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty)
    }
}

// MARK: - Background transfer manager (#4, #7)

final class BackgroundTransferManagerTests: XCTestCase {

    /// Holds every request open until it is cancelled, like a long upload.
    private final class StalledProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    private func makeManager() -> BackgroundTransferManager {
        let manager = BackgroundTransferManager(identifier: "tests.\(UUID().uuidString)",
                                                registryDirectory: TestFiles.temporaryDirectory(),
                                                usesBackgroundSession: false,
                                                logger: SilentCloudConvertLogger())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StalledProtocol.self]
        manager.session = URLSession(configuration: configuration, delegate: manager, delegateQueue: nil)
        return manager
    }

    /// Starts an upload and returns its waiter once the task is in flight.
    private func startUpload(on manager: BackgroundTransferManager, id: String) async throws -> (Task<TransferOutcome, Error>, URLSessionTask) {
        let body = try TestFiles.makeFile(named: "body.bin")
        var request = URLRequest(url: URL(string: "https://upload.example/form")!)
        request.httpMethod = "POST"
        let waiter = Task { try await manager.upload(id: id, request: request, bodyFile: body) { _ in } }
        for _ in 0..<300 {
            if let task = await manager.session.allTasks.first(where: { $0.taskDescription == id }) { return (waiter, task) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CloudConvertError.transferLost(id: id)
    }

    /// #4: iOS cancels background transfers when the user force-quits the
    /// app. That is a lost transfer, to start again, not a user cancellation
    /// (which would delete the paid job).
    func testCancellationByTheSystemIsALostTransfer() async throws {
        let manager = makeManager()
        let (waiter, task) = try await startUpload(on: manager, id: "cancelled-by-the-system")

        task.cancel()

        do {
            _ = try await waiter.value
            XCTFail("expected an error")
        } catch CloudConvertError.transferLost(let id) {
            XCTAssertEqual(id, "cancelled-by-the-system")
        } catch {
            XCTFail("expected transferLost, got \(error)")
        }
    }

    /// #4: a cancellation the engine asked for is still a cancellation.
    func testCancellationTheEngineAskedForIsACancellation() async throws {
        let manager = makeManager()
        let (waiter, _) = try await startUpload(on: manager, id: "cancelled-by-the-user")

        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("expected an error")
        } catch CloudConvertError.cancelled {
        } catch {
            XCTFail("expected cancelled, got \(error)")
        }
    }

    /// #7: engines created at the same time for one identifier share one
    /// manager, so one background session.
    func testConcurrentCreationMakesOneManagerPerIdentifier() async {
        let identifier = "tests.\(UUID().uuidString)"
        let directory = TestFiles.temporaryDirectory()
        let made = Counter()
        let managers = await withTaskGroup(of: ObjectIdentifier.self) { group -> Set<ObjectIdentifier> in
            for _ in 0..<16 {
                group.addTask {
                    ObjectIdentifier(BackgroundTransferManager.shared(for: identifier) {
                        _ = made.next()
                        Thread.sleep(forTimeInterval: 0.01)     // widen the window a check-then-create loses
                        return BackgroundTransferManager(identifier: identifier, registryDirectory: directory,
                                                         usesBackgroundSession: false, logger: SilentCloudConvertLogger())
                    })
                }
            }
            return await group.reduce(into: []) { $0.insert($1) }
        }
        XCTAssertEqual(managers.count, 1)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(BackgroundTransferManager.shared(for: identifier).map(ObjectIdentifier.init), managers.first)
    }
}

// MARK: - Connectivity (#5)

final class ConnectivityMonitorTests: XCTestCase {

    /// Each path reading hops onto the actor in its own task, so a newer one
    /// can land first. The older one must not overwrite it, or the monitor
    /// reports offline, and refuses every request, while the device is online.
    func testAnOlderPathReadingDoesNotOverwriteANewerOne() async {
        let monitor = ConnectivityMonitor()
        await monitor.update(1_000_001, connected: true, expensive: false)
        await monitor.update(1_000_000, connected: false, expensive: false)
        let connected = await monitor.isConnected
        XCTAssertTrue(connected)
    }

    func testOnlyAnUnsatisfiedPathIsOffline() {
        XCTAssertTrue(ConnectivityMonitor.isUsable(.satisfied))
        XCTAssertTrue(ConnectivityMonitor.isUsable(.requiresConnection), "an on-demand VPN comes up when a request is made")
        XCTAssertFalse(ConnectivityMonitor.isUsable(.unsatisfied))
    }
}

// MARK: - Everything else the review found

final class ReviewFixesTests: XCTestCase {

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
        engine = ConversionEngine(configuration: configuration, api: api, transfers: transfers, connectivity: AlwaysOnline())
    }

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func request(_ name: String = "book.epub", to format: String = "mobi") throws -> ConversionRequest {
        ConversionRequest.convert(try TestFiles.makeFile(named: name), to: format)
    }

    // #6: values the server or a proxy controls never trap.

    func testRetryAfterIsFiniteAndBounded() {
        for raw in ["inf", "-inf", "nan", "1e30", "99999999999999999999"] {
            let delay = HTTPResponse(status: 429, headers: ["Retry-After": raw], body: Data()).retryAfter
            XCTAssertTrue(delay.map { $0.isFinite && $0 >= 0 && $0 <= HTTPResponse.maxRetryAfter } ?? true, raw)
        }
        let farFuture = HTTPResponse(status: 429, headers: ["Retry-After": "Fri, 31 Dec 9999 23:59:59 GMT"], body: Data())
        XCTAssertEqual(farFuture.retryAfter, HTTPResponse.maxRetryAfter)
        XCTAssertEqual(HTTPResponse(status: 429, headers: ["Retry-After": "7"], body: Data()).retryAfter, 7)
    }

    func testNumbersOutOfRangeDecodeAsUnknown() throws {
        for credits in [#""inf""#, "1e20", #""1e20""#, #""nan""#] {
            let json = #"{"id":"t","operation":"convert","status":"finished","credits":\#(credits)}"#
            XCTAssertNil(try CCDateDecoding.makeDecoder().decode(CCTask.self, from: Data(json.utf8)).credits, credits)
        }
        let whole = #"{"id":"t","operation":"convert","status":"finished","credits":2.0}"#
        XCTAssertEqual(try CCDateDecoding.makeDecoder().decode(CCTask.self, from: Data(whole.utf8)).credits, 2)
        XCTAssertNil(JSONValue.double(1e20).intValue)
        XCTAssertNil(JSONValue.double(.infinity).intValue)
        XCTAssertNil(JSONValue.double(2.5).intValue)
        XCTAssertEqual(JSONValue.double(3).intValue, 3)
        XCTAssertEqual([Int64.max, 1].saturatingSum(), .max)
        XCTAssertEqual([Int.min, -1].saturatingSum(), .min)
    }

    func testAnInfiniteRetryAfterWaitsInsteadOfTrapping() async throws {
        api.createJobError = .rateLimited(retryAfter: .infinity)
        let engine = self.engine!, conversionRequest = try request()
        let log = StageLog()
        let conversion = Task { try await engine.convert(conversionRequest) { log.append($0.stage) } }
        await waitUntil { log.snapshot.contains { if case .retrying(_, _, .job, _) = $0 { return true }; return false } }
        conversion.cancel()

        do {
            _ = try await conversion.value
            XCTFail("expected cancellation")
        } catch let error as CloudConvertError {
            guard case .cancelled = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testAbsurdOutputSizesDoNotTrap() async throws {
        api.exportFiles = [(filename: "a.pdf", size: .max, url: "https://storage.example/a"),
                           (filename: "b.pdf", size: .max, url: "https://storage.example/b")]
        do {
            _ = try await engine.convert(try request("scan.pdf", to: "pdf"))
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .insufficientDiskSpace = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // #8

    /// A multi-file conversion that fails after saving some outputs removes
    /// them: nobody was told about them.
    func testFailedMultiFileConversionRemovesTheOutputsItSaved() async throws {
        api.exportFiles = [(filename: "page-1.jpg", size: 9, url: "https://storage.example/1"),
                           (filename: "page-2.jpg", size: 9, url: "https://storage.example/2")]
        transfers.downloadStatuses = [200, 500]      // the second page never downloads

        do {
            _ = try await engine.convert(try request("scan.pdf", to: "jpg"))
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .downloadFailed = error else { return XCTFail("unexpected \(error)") }
        }
        let outputs = (try? FileManager.default.contentsOfDirectory(atPath: configuration.outputDirectory.path)) ?? []
        XCTAssertTrue(outputs.isEmpty, "left behind: \(outputs)")
    }

    // #9

    /// Cancelling while the engine asks the server whether an upload arrived
    /// is a cancellation, not a failure.
    func testCancellingDuringTheArrivalCheckIsACancellation() async throws {
        transfers.lostResponses = 1                                             // the upload arrives, its response is lost
        api.getJobErrors = [.serverError(status: 503, nil), .serverError(status: 503, nil)]  // and the upload loop can't tell
        let calls = Counter(), gate = Gate()
        api.getJobHook = { _ in if calls.next() == 3 { try await gate.wait() } }    // the job-level check hangs
        let log = StageLog()

        let handle = engine.start(try request())
        let observer = Task { for await progress in handle.progress { log.append(progress.stage) } }
        await waitUntil { calls.count >= 3 }
        handle.cancel()

        do {
            _ = try await handle.result
            XCTFail("expected cancellation")
        } catch let error as CloudConvertError {
            guard case .cancelled = error else { return XCTFail("unexpected \(error)") }
        }
        await observer.value
        XCTAssertEqual(log.snapshot.last, .cancelled)
    }

    // #10

    /// A conversion cancelled while still queued ends with `.cancelled` too.
    func testConversionCancelledWhileQueuedEndsWithCancelled() async throws {
        transfers.uploadDelay = 0.3
        let queue = ConversionQueue(engine: engine, maxConcurrent: 1)
        let first = await queue.enqueue(try request("a.epub"))
        let second = await queue.enqueue(try request("b.epub"))
        let log = StageLog()
        let observer = Task { for await progress in second.progress { log.append(progress.stage) } }
        try await Task.sleep(nanoseconds: 50_000_000)

        second.cancel()

        do {
            _ = try await second.result
            XCTFail("expected cancellation")
        } catch {}
        await observer.value
        XCTAssertEqual(log.snapshot, [.cancelled])
        _ = try await first.result
    }

    // #11

    /// The "did the upload arrive?" check finding the job gone (404) rebuilds
    /// the job, instead of failing with `.notFound`.
    func testJobGoneDuringUploadRetriesIsRebuilt() async throws {
        transfers.lostResponses = 1                  // the first upload's response is lost
        api.getJobErrors = [.notFound(nil)]          // and the job is gone when asked

        let result = try await engine.convert(try request())

        XCTAssertEqual(result.jobID, "job-2")
        XCTAssertEqual(api.createdSpecifications.count, 2)
    }

    // #12

    func testAnOutputTheServerSaysIsEmptyIsAccepted() async throws {
        api.exportFiles = [(filename: "notes.txt", size: 0, url: "https://storage.example/notes.txt")]
        transfers.downloadContent = Data()

        let result = try await engine.convert(try request("notes.docx", to: "txt"))

        XCTAssertEqual(result.files.map(\.size), [0])
        XCTAssertEqual(transfers.downloads.count, 1, "not retried")
    }

    func testAnEmptyDownloadOfAnOutputThatIsNotEmptyStillFails() async throws {
        transfers.downloadContent = Data()            // the server said 10 bytes
        do {
            _ = try await engine.convert(try request())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .downloadFailed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // Suspected: URLs decoded differently before iOS 17 / macOS 14.

    func testURLsDecodeTheSameOnEverySystem() throws {
        // What iOS 17 and macOS 14 make of each; older systems returned nil.
        let expected = [
            "https://s.example/a b.pdf?x=1 2#f g": "https://s.example/a%20b.pdf?x=1%202#f%20g",
            "https://s.example/a|b[1].pdf": "https://s.example/a%7Cb%5B1%5D.pdf",
            "https://s.example/ü.pdf": "https://s.example/%C3%BC.pdf",
            "https://[::1]:8080/a b": "https://[::1]:8080/a%20b",
            "https://s.example/50%off": "https://s.example/50%25off",
            "https://s.example/a%20b": "https://s.example/a%20b",
        ]
        for (raw, encoded) in expected {
            XCTAssertEqual(URL.encodingInvalidCharacters(raw), encoded, raw)
            XCTAssertEqual(URL(lenient: raw)?.absoluteString, encoded, raw)
        }
        let json = #"{"files":[{"filename":"a b.pdf","size":1,"url":"https://storage.example/a b.pdf"}]}"#
        let result = try JSONDecoder().decode(CCTaskResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.files?.map(\.url.absoluteString), ["https://storage.example/a%20b.pdf"], "the file is not dropped")
    }

    // Suspected: a device clock running ahead failed every upload.

    func testAFreshFormIsUsedWhateverTheDeviceClockSays() async throws {
        api.formExpiresIn = -3600                     // by the device clock, every form expired an hour ago

        let result = try await engine.convert(try request())

        XCTAssertEqual(result.jobID, "job-1")
        XCTAssertEqual(api.createdSpecifications.count, 1)
    }

    /// A form a previous launch received that the device clock says has
    /// expired still leads to a new job, as before.
    func testAnOldFormThatLooksExpiredRebuildsTheJob() async throws {
        _ = try await seedPreviousLaunch(phase: .uploading, configuration: configuration, api: api)
        api.formExpiresIn = -3600
        api.jobStatusScript = [.waiting, .processing, .finished]

        let handles = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-1", "a new job")
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    /// When no new job is allowed any more, the device clock can't fail the
    /// upload: storage judges the form.
    func testAnOldFormAtTheLastAttemptIsLeftToStorage() async throws {
        _ = try await seedPreviousLaunch(phase: .uploading, configuration: configuration, api: api) { $0.jobAttempt = 2 }
        api.formExpiresIn = -3600
        api.jobStatusScript = [.waiting, .processing, .finished]

        let handles = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-9")
        XCTAssertTrue(api.createdSpecifications.isEmpty)
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    // Suspected: user content in logs and alert text.

    func testFileNamesAndServerTextStayOutOfLogMessages() async throws {
        let recorder = LogRecorder()
        configuration.logger = recorder
        engine = ConversionEngine(configuration: configuration, api: api, transfers: transfers, connectivity: AlwaysOnline())
        api.exportFiles = [(filename: "Payslip March.pdf", size: 10, url: "https://storage.example/out.pdf")]
        _ = try await engine.convert(try request("Payslip March.docx", to: "pdf"))
        api.jobStatusScript = [.error]
        api.failureCode = "ENGINE_EXPLODED"           // the task's message is "scripted failure"
        _ = try? await engine.convert(try request("Payslip April.docx", to: "pdf"))

        XCTAssertFalse(recorder.messages.contains { $0.contains("Payslip") }, "file names belong in (private) metadata")
        XCTAssertFalse(recorder.messages.contains { $0.contains("scripted failure") }, "so does the server's text")
        XCTAssertTrue(recorder.metadataValues.contains { $0.contains("Payslip") })
        XCTAssertTrue(recorder.metadataValues.contains("scripted failure"))

        let failure = CloudConvertError.jobFailed(jobID: "j", taskName: "convert", code: .other("ENGINE_EXPLODED"),
                                                  message: "Payslip March.pdf is encrypted")
        XCTAssertFalse(failure.userFacingMessage.contains("Payslip"))
    }

    // Suspected: the free-space check.

    func testFreeSpaceCountsTheUploadBodyAndTheOutputs() {
        // A 64 MB video compressed to 1 MB still needs room for its 64 MB upload body.
        XCTAssertEqual(ConversionEngine.requiredFreeSpace(inputSizes: [64 << 20], expectedOutputBytes: 1 << 20), 64 << 20)
        XCTAssertEqual(ConversionEngine.requiredFreeSpace(inputSizes: [10], expectedOutputBytes: 100), 100)
        XCTAssertEqual(ConversionEngine.requiredFreeSpace(inputSizes: [10, 20], expectedOutputBytes: nil), 60, "unchanged without an estimate")
    }

    /// What copying onto a full disk throws, from Foundation or from a POSIX
    /// call. Staging reports both as `.insufficientDiskSpace`, not as a file
    /// that cannot be read.
    func testAFullDiskIsInsufficientSpace() {
        for error: Error in [NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), POSIXError(.ENOSPC)] {
            guard case .insufficientDiskSpace = CloudConvertError.wrap(error, phase: .preparing) else {
                return XCTFail("not insufficientDiskSpace: \(error)")
            }
        }
    }
}

// MARK: - Helpers

/// Polls `condition` until it holds or `timeout` elapses.
private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
}

private func outcome(_ status: Int) -> TransferOutcome {
    TransferOutcome(status: status, responseBody: nil, fileURL: nil, errorDescription: nil, urlErrorCode: nil, finishedAt: Date())
}

/// A conversion a previous launch left behind: its input staged and its job
/// (`jobID`) created, saved where the engine finds pending records.
@discardableResult
func seedPreviousLaunch(id: String = "previous",
                        phase: ConversionPhase,
                        jobID: String = "job-9",
                        configuration: CloudConvertConfiguration,
                        api: FakeAPI,
                        change: (inout ConversionRecord) -> Void = { _ in }) async throws -> ConversionRecord {
    let url = try TestFiles.makeFile(named: "book.epub")
    let specification = try ConversionRequest.convert(url, to: "mobi").makeJobSpecification(defaultTag: nil, defaultTimeout: nil)
    let storage = FileStorage(workingDirectory: configuration.workingDirectory, outputDirectory: configuration.outputDirectory,
                              diskSpaceSafetyMargin: 0)
    let staged = try storage.stage(InputFile(url: url), conversionID: id, limit: .max)
    var record = ConversionRecord(id: id,
                                  specification: specification,
                                  staged: ["import-1": staged],
                                  output: .default,
                                  userInfo: [:],
                                  createdAt: Date().addingTimeInterval(-60),
                                  updatedAt: Date(),
                                  phase: phase,
                                  jobAttempt: 1,
                                  jobID: jobID,
                                  uploadTransfers: [:],
                                  uploadedTaskNames: phase == .uploading ? [] : ["import-1"],
                                  downloadTransfers: [:],
                                  exportedFiles: [])
    change(&record)
    await ConversionRecordStore(directory: storage.recordsDirectory, logger: SilentCloudConvertLogger()).save(record)
    api.seededSpecification = specification
    return record
}

//  The conversion pipeline end to end, against the fakes and against the
//  real API client over a scripted transport.
//

import XCTest
import Network
@testable import CloudConvertKit

// MARK: - Pipeline

final class ConversionEngineTests: XCTestCase {

    private var api: FakeAPI!
    private var transfers: FakeTransfers!
    private var configuration: CloudConvertConfiguration!
    private var engine: ConversionEngine!

    private var workingDirectory: URL!
    private var outputDirectory: URL!

    override func setUp() {
        super.setUp()
        api = FakeAPI()
        transfers = FakeTransfers()
        workingDirectory = TestFiles.temporaryDirectory()
        outputDirectory = TestFiles.temporaryDirectory()
        configuration = .testing(workingDirectory: workingDirectory, outputDirectory: outputDirectory)
        let transfers = self.transfers!
        api.serverHasUpload = { transfers.receivedUploadsSnapshot > 0 }
        engine = ConversionEngine(configuration: configuration, api: api, transfers: transfers, connectivity: AlwaysOnline())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workingDirectory)
        try? FileManager.default.removeItem(at: outputDirectory)
        super.tearDown()
    }

    private func makeRequest(name: String = "report.docx", bytes: Int = 4096) throws -> ConversionRequest {
        let url = try TestFiles.makeFile(named: name, bytes: bytes)
        return ConversionRequest.convert(url, to: "pdf")
    }

    // MARK: Happy path

    func testSuccessfulConversionProducesFileWithOriginalName() async throws {
        let request = try makeRequest()
        let log = StageLog()

        let result = try await engine.convert(request) { log.append($0.stage) }

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].filename, "report.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.files[0].url.path))
        XCTAssertEqual(result.files[0].url.deletingLastPathComponent().standardizedFileURL, configuration.outputDirectory.standardizedFileURL)
        XCTAssertEqual(api.createdSpecifications.count, 1)
        XCTAssertEqual(transfers.uploads.count, 1)
        XCTAssertEqual(transfers.downloads.count, 1)
        await waitUntil { !self.api.deletedJobIDsSnapshot.isEmpty }
        XCTAssertEqual(api.deletedJobIDsSnapshot.first, "job-1")

        let observed = log.snapshot
        XCTAssertTrue(observed.contains(.creatingJob))
        XCTAssertTrue(observed.contains(.uploading))
        XCTAssertTrue(observed.contains(.processing))
        XCTAssertTrue(observed.contains(.downloading))
        XCTAssertEqual(observed.last, .completed)

        // Working files are cleaned up.
        let staging = configuration.workingDirectory.appendingPathComponent("staging")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testJobSpecificationCarriesFormatsOptionsAndTimeout() throws {
        let url = try TestFiles.makeFile(named: "song.wav")
        var request = ConversionRequest.convert(url, to: "mp3", options: ["audio_bitrate": 192, "audio_channels": 2])
        request.timeout = 120
        let spec = try request.makeJobSpecification(defaultTag: "audio-app", defaultTimeout: 900)

        XCTAssertEqual(spec.tag, "audio-app")
        XCTAssertEqual(spec.uploadTaskNames, ["import-1"])
        XCTAssertEqual(spec.exportTaskName, "export-1")
        let convert = try XCTUnwrap(spec.task(named: "process-1"))
        XCTAssertEqual(convert.operation, "convert")
        XCTAssertEqual(convert.inputs, ["import-1"])
        XCTAssertEqual(convert.options["output_format"], "mp3")
        XCTAssertEqual(convert.options["input_format"], "wav")
        XCTAssertEqual(convert.options["audio_bitrate"], 192)
        XCTAssertEqual(convert.options["timeout"], 120)

        let body = spec.requestBody
        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tasks = try XCTUnwrap(json["tasks"] as? [String: Any])
        XCTAssertEqual(Set(tasks.keys), ["import-1", "process-1", "export-1"])
        let export = try XCTUnwrap(tasks["export-1"] as? [String: Any])
        XCTAssertEqual(export["input"] as? String, "process-1")
    }

    func testMergeUsesSingleTaskWithArrayInput() throws {
        let a = try TestFiles.makeFile(named: "a.pdf")
        let b = try TestFiles.makeFile(named: "b.jpg")
        let spec = try ConversionRequest.merge([a, b], outputFilename: "combined.pdf").makeJobSpecification(defaultTag: nil, defaultTimeout: nil)
        let merge = try XCTUnwrap(spec.task(named: "process-1"))
        XCTAssertEqual(merge.operation, "merge")
        XCTAssertEqual(merge.inputs, ["import-1", "import-2"])
        XCTAssertEqual(merge.options["filename"], "combined.pdf")
        XCTAssertEqual(merge.wireObject["input"], ["import-1", "import-2"])
    }

    // MARK: Failure handling

    func testDeterministicJobFailureIsNotRetried() async throws {
        api.jobStatusScript = [.processing, .error]
        api.failureCode = "INVALID_CONVERSION_TYPE"

        do {
            _ = try await engine.convert(try makeRequest())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .jobFailed(_, _, let code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, .invalidConversionType)
            XCTAssertFalse(error.isRetryable)
        }
        XCTAssertEqual(api.createdSpecifications.count, 1, "must not rebuild the job")
        await waitUntil { !self.api.deletedJobIDsSnapshot.isEmpty }
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-1"])
    }

    func testTransientJobFailureRebuildsJobOnce() async throws {
        // First job errors with a retryable code, second succeeds.
        api.jobStatusScripts = [[.error], [.finished]]
        api.failureCode = "TIMEOUT"

        let result = try await engine.convert(try makeRequest())

        XCTAssertEqual(result.jobID, "job-2")
        XCTAssertEqual(api.createdSpecifications.count, 2)
        XCTAssertEqual(transfers.uploads.count, 2, "a rebuilt job uploads again")
    }

    func testUploadRejectedByStorageRebuildsJob() async throws {
        transfers.uploadStatuses = [403, 201]   // expired policy → fresh job → success
        let result = try await engine.convert(try makeRequest())
        XCTAssertEqual(result.jobID, "job-2")
        XCTAssertEqual(api.createdSpecifications.count, 2)
    }

    func testMissingInputFailsBeforeCreatingJob() async {
        let missing = URL(fileURLWithPath: "/nonexistent/file.docx")
        do {
            _ = try await engine.convert(ConversionRequest.convert(missing, to: "pdf"))
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .fileNotFound = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(api.createdSpecifications.isEmpty)
    }

    func testEmptyExportFails() async throws {
        api.exportFiles = []
        do {
            _ = try await engine.convert(try makeRequest())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .exportMissing = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testMultipleExportedFilesAreAllDownloaded() async throws {
        api.exportFiles = [(filename: "page-1.jpg", size: 9, url: "https://storage.example/1"),
                           (filename: "page-2.jpg", size: 9, url: "https://storage.example/2")]
        let url = try TestFiles.makeFile(named: "scan.pdf")
        let result = try await engine.convert(ConversionRequest.convert(url, to: "jpg"))
        XCTAssertEqual(result.files.map(\.filename).sorted(), ["page-1.jpg", "page-2.jpg"])
        XCTAssertEqual(transfers.downloads.count, 2)
    }

    // MARK: Cancellation

    func testCancellationDuringUploadCleansUp() async throws {
        transfers.uploadDelay = 1
        let request = try makeRequest()
        let handle = engine.start(request)
        await waitUntil { !self.transfers.uploads.isEmpty }    // uploading: the job exists
        handle.cancel()

        do {
            _ = try await handle.result
            XCTFail("expected cancellation")
        } catch let error as CloudConvertError {
            guard case .cancelled = error else { return XCTFail("unexpected \(error)") }
        }
        await waitUntil { !self.api.deletedJobIDsSnapshot.isEmpty }
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-1"])
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: Queue

    func testQueueLimitsConcurrency() async throws {
        transfers.uploadDelay = 0.05
        let queue = ConversionQueue(engine: engine, maxConcurrent: 1)
        let handles = await queue.enqueue([try makeRequest(name: "a.docx"), try makeRequest(name: "b.docx")])
        for handle in handles { _ = try await handle.result }
        XCTAssertEqual(transfers.maxConcurrentUploads, 1)
        XCTAssertEqual(transfers.uploads.count, 2)
    }

    // MARK: Phase-level retry

    func testUploadServerErrorRetriesSameJobAndReportsRetrying() async throws {
        transfers.uploadStatuses = [503, 201]
        let log = StageLog()

        let result = try await engine.convert(try makeRequest()) { log.append($0.stage) }

        XCTAssertEqual(result.jobID, "job-1")
        XCTAssertEqual(api.createdSpecifications.count, 1, "a 5xx from storage retries the same upload form, not a new job")
        XCTAssertEqual(transfers.uploads.count, 2)
        let sawRetry = log.snapshot.contains {
            if case .retrying(attempt: 1, delay: _, scope: .phase(.uploading), reason: _) = $0 { return true }
            return false
        }
        XCTAssertTrue(sawRetry, "the UI must be told about phase-level retries")
        XCTAssertEqual(log.snapshot.last, .completed)
    }

    // MARK: Offline

    func testOfflineTimeoutFailsOnceWithoutRebuildingJob() async throws {
        engine = ConversionEngine(configuration: configuration, api: api, transfers: transfers, connectivity: AlwaysOffline())
        let log = StageLog()

        do {
            _ = try await engine.convert(try makeRequest()) { log.append($0.stage) }
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

    // MARK: Cancellation during the rebuild delay

    func testCancellationDuringRebuildDelayCleansUp() async throws {
        configuration.jobRetryPolicy = RetryPolicy(maxAttempts: 2, baseDelay: 1, maxDelay: 1, jitter: 0)
        engine = ConversionEngine(configuration: configuration, api: api, transfers: transfers, connectivity: AlwaysOnline())
        api.jobStatusScript = [.error]
        api.failureCode = "TIMEOUT"
        let log = StageLog()

        let handle = engine.start(try makeRequest())
        let observer = Task { for await progress in handle.progress { log.append(progress.stage) } }
        await waitUntil(timeout: 3) {
            log.snapshot.contains { if case .retrying(_, _, .job, _) = $0 { return true }; return false }
        }
        handle.cancel()

        do {
            _ = try await handle.result
            XCTFail("expected cancellation")
        } catch let error as CloudConvertError {
            guard case .cancelled = error else { return XCTFail("unexpected \(error)") }
        }
        await observer.value
        XCTAssertEqual(log.snapshot.last, .cancelled)
        XCTAssertEqual(api.createdSpecifications.count, 1, "cancelled before the rebuild started")
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty, "the record must not survive to be resumed at next launch")
    }

    // MARK: Pending / resume

    func testRunningConversionIsNotReportedAsPending() async throws {
        transfers.uploadDelay = 0.2
        let handle = engine.start(try makeRequest())
        await waitUntil { !self.transfers.uploads.isEmpty }

        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty, "a conversion running in this process is not pending")
        let resumed = await engine.resumePendingConversions()
        XCTAssertTrue(resumed.isEmpty, "and must not be started a second time")

        _ = try await handle.result
        XCTAssertEqual(api.createdSpecifications.count, 1)
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    func testResumeContinuesProcessingWithoutReuploading() async throws {
        // Simulate a previous launch: input staged, job created, upload done,
        // app killed while the server was converting.
        let url = try TestFiles.makeFile(named: "book.epub")
        let spec = try ConversionRequest.convert(url, to: "mobi").makeJobSpecification(defaultTag: nil, defaultTimeout: nil)
        let stagedDirectory = workingDirectory.appendingPathComponent("staging/resume-1", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        let stagedURL = stagedDirectory.appendingPathComponent("book.epub")
        try FileManager.default.copyItem(at: url, to: stagedURL)
        let record = ConversionRecord(id: "resume-1",
                                      specification: spec,
                                      staged: ["import-1": StagedInput(original: InputFile(url: url), stagedURL: stagedURL, filename: "book.epub", size: 1024)],
                                      output: .default,
                                      userInfo: ["historyRow": "7"],
                                      createdAt: Date().addingTimeInterval(-60),
                                      updatedAt: Date(),
                                      phase: .processing,
                                      jobAttempt: 1,
                                      jobID: "job-9",
                                      uploadTransfers: [:],
                                      uploadedTaskNames: ["import-1"],
                                      downloadTransfers: [:],
                                      exportedFiles: [])
        let store = ConversionRecordStore(directory: workingDirectory.appendingPathComponent("records"), logger: SilentCloudConvertLogger())
        await store.save(record)
        api.seededSpecification = spec
        api.jobStatusScript = [.processing, .finished]
        api.exportFiles = [(filename: "book.mobi", size: 10, url: "https://storage.example/book.mobi")]

        let handles = await engine.resumePendingConversions()
        XCTAssertEqual(handles.count, 1)
        let result = try await handles[0].result

        XCTAssertEqual(result.jobID, "job-9")
        XCTAssertEqual(result.userInfo["historyRow"], "7")
        XCTAssertEqual(result.files.map(\.filename), ["book.mobi"])
        XCTAssertTrue(transfers.uploads.isEmpty, "the upload had already completed; it must not be repeated")
        XCTAssertTrue(api.createdSpecifications.isEmpty, "the existing job is reused, not recreated")
        XCTAssertEqual(transfers.downloads.count, 1)
        await waitUntil { self.api.deletedJobIDsSnapshot == ["job-9"] }
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty)
    }
}

// MARK: - Control, limits, keys and account

final class EngineControlTests: XCTestCase {

    private var api: FakeAPI!
    private var transfers: FakeTransfers!
    private var configuration: CloudConvertConfiguration!

    override func setUp() {
        super.setUp()
        api = FakeAPI()
        transfers = FakeTransfers()
        configuration = .testing(workingDirectory: TestFiles.temporaryDirectory(), outputDirectory: TestFiles.temporaryDirectory())
        let transfers = self.transfers!
        api.serverHasUpload = { transfers.receivedUploadsSnapshot > 0 }
    }

    private func makeEngine(connectivity: any ConnectivityMonitoring = AlwaysOnline()) -> ConversionEngine {
        ConversionEngine(configuration: configuration, api: api, transfers: transfers, connectivity: connectivity)
    }

    private func request(_ name: String = "report.docx", key: String? = nil) throws -> ConversionRequest {
        var request = ConversionRequest.convert(try TestFiles.makeFile(named: name), to: "pdf")
        request.key = key
        return request
    }

    func testOutputsAreReadableByEveryone() async throws {
        let result = try await makeEngine().convert(try request())
        let permissions = try FileManager.default.attributesOfItem(atPath: result.files[0].url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o644)
    }

    func testCreditsAreReported() async throws {
        api.taskCredits = 3
        let result = try await makeEngine().convert(try request())
        XCTAssertEqual(result.credits, 3)
    }

    func testTheEngineRunsNoMoreThanItsLimitAtOnce() async throws {
        configuration.maxConcurrentConversions = 1
        transfers.uploadDelay = 0.05
        let engine = makeEngine()
        let requests = try (0..<3).map { try request("file\($0).docx") }
        try await withThrowingTaskGroup(of: ConversionResult.self) { group in
            for request in requests { group.addTask { try await engine.convert(request) } }
            for try await _ in group {}
        }
        XCTAssertEqual(transfers.maxConcurrentUploads, 1)
    }

    func testCancelByIDStopsTheConversion() async throws {
        transfers.uploadDelay = 2
        let engine = makeEngine()
        let request = try request()
        let task = Task { try await engine.convert(request, conversionID: "the-one") }
        await waitUntil { !self.transfers.uploads.isEmpty }
        engine.cancel(id: "the-one")
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as CloudConvertError {
            XCTAssertTrue(error.isCancellation)
        }
    }

    func testCancelAllStopsEveryConversion() async throws {
        transfers.uploadDelay = 2
        let engine = makeEngine()
        let requests = try (0..<2).map { try request("f\($0).docx") }
        let tasks = requests.map { request in Task { try await engine.convert(request) } }
        await waitUntil { self.transfers.uploads.count == 2 }
        engine.cancelAll()
        for task in tasks {
            let result = await task.result
            XCTAssertThrowsError(try result.get())
        }
    }

    // MARK: Keyed requests

    func testAKeyedRequestContinuesItsKeptConversionInsteadOfConvertingAgain() async throws {
        configuration.polling.jobTimeout = 0.05
        api.jobStatusScript = [.processing]
        let engine = makeEngine()
        let request = try request(key: "row-1")

        do {
            _ = try await engine.convert(request)
            XCTFail("expected the job to time out")
        } catch let error as CloudConvertError {
            XCTAssertTrue(error.isResumable)
        }
        api.jobStatusScript = [.finished]
        let result = try await engine.convert(request)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(api.createdJobIDs.count, 1, "the kept job is continued, not converted again")
    }

    func testAKeyedRequestStartsOverWhenItsKeptConversionExpired() async throws {
        configuration.polling.jobTimeout = 0.05
        api.jobStatusScript = [.processing]
        let engine = makeEngine()
        let request = try request(key: "row-2")
        _ = try? await engine.convert(request)

        // Make the kept record a day old.
        let store = ConversionRecordStore(directory: FileStorage(workingDirectory: configuration.workingDirectory,
                                                                outputDirectory: configuration.outputDirectory,
                                                                diskSpaceSafetyMargin: 0).recordsDirectory,
                                          logger: SilentCloudConvertLogger())
        var record = try await XCTUnwrapAsync(await store.all().first)
        XCTAssertFalse(record.isExpired())
        record.createdAt = Date().addingTimeInterval(-25 * 60 * 60)
        await store.save(record)

        api.jobStatusScripts = [[.processing], [.processing, .finished]]
        let result = try await engine.convert(request)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(api.createdJobIDs.count, 2)
        await waitUntil { self.api.deletedJobIDsSnapshot.contains("job-1") }
        XCTAssertTrue(api.deletedJobIDsSnapshot.contains("job-1"))
    }

    func testTwoConversionsWithOneKeyNeverRunTogether() async throws {
        transfers.uploadDelay = 0.3
        let engine = makeEngine()
        let request = try request(key: "row-3")
        let first = Task { try await engine.convert(request) }
        await waitUntil { !self.transfers.uploads.isEmpty }
        do {
            _ = try await engine.convert(request)
            XCTFail("expected the second conversion to be refused")
        } catch let error as CloudConvertError {
            guard case .invalidRequest = error else { return XCTFail("got \(error)") }
        }
        _ = try await first.value
        XCTAssertEqual(api.createdJobIDs.count, 1)
    }

    func testAKeyedRequestFollowsTheResumeTheAppStarted() async throws {
        configuration.polling.jobTimeout = 0.05
        api.jobStatusScript = [.processing]
        let engine = makeEngine()
        let request = try request(key: "row-4")
        _ = try? await engine.convert(request)

        let gate = Gate()
        api.jobStatusScript = [.finished]
        api.getJobHook = { _ in try await gate.wait() }
        let resumed = try await XCTUnwrapAsync(await engine.resumePendingConversions().first)
        let keyed = Task { try await engine.convert(request) }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.open()

        let viaKey = try await keyed.value
        let viaResume = try await resumed.result
        XCTAssertEqual(viaKey.conversionID, viaResume.conversionID, "the keyed request followed the running resume")
        XCTAssertEqual(api.createdJobIDs.count, 1)
    }

    // MARK: Slots

    func testAConversionCancelledWhileWaitingForASlotNeverStarts() async throws {
        configuration.maxConcurrentConversions = 1
        transfers.uploadDelay = 0.3
        let engine = makeEngine()
        let first = Task { try await engine.convert(try self.request("a.docx")) }
        await waitUntil { !self.transfers.uploads.isEmpty }

        let log = StageLog()
        let second = Task { try await engine.convert(try self.request("b.docx")) { log.append($0.stage) } }
        await waitUntil { !log.snapshot.isEmpty }
        second.cancel()
        let result = await second.result
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(log.snapshot, [.preparing, .cancelled])

        _ = try await first.value
        XCTAssertEqual(api.createdJobIDs.count, 1, "the cancelled one never created a job")
    }

    func testAResumeCancelledWhileWaitingForASlotIsGivenUp() async throws {
        configuration.polling.jobTimeout = 0.05
        configuration.maxConcurrentConversions = 1
        api.jobStatusScript = [.processing]
        let engine = makeEngine()
        _ = try? await engine.convert(try request("kept.docx"))
        api.jobStatusScript = [.finished]

        transfers.uploadDelay = 0.3
        let busy = Task { try await engine.convert(try self.request("busy.docx")) }
        await waitUntil { self.transfers.uploads.count == 2 }
        let resumed = try await XCTUnwrapAsync(await engine.resumePendingConversions().first)
        resumed.cancel()
        do {
            _ = try await resumed.result
            XCTFail("expected cancellation")
        } catch let error as CloudConvertError {
            XCTAssertTrue(error.isCancellation)
        }
        _ = try await busy.value
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty)
        await waitUntil { self.api.deletedJobIDsSnapshot.contains("job-1") }
        XCTAssertTrue(api.deletedJobIDsSnapshot.contains("job-1"), "the kept job is deleted")
    }

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

    // MARK: Network

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

    // MARK: Account

    private final class Observer: AccountObserving, @unchecked Sendable {
        let problem: XCTestExpectation
        let low: XCTestExpectation
        private let lock = NSLock()
        private var remaining: Int?
        var lowBalance: Int? { lock.lock(); defer { lock.unlock() }; return remaining }
        init(problem: XCTestExpectation, low: XCTestExpectation) { self.problem = problem; self.low = low }
        func conversionStopped(byAccountProblem error: CloudConvertError) { problem.fulfill() }
        func creditsRunningLow(remaining: Int) { lock.withLock { self.remaining = remaining }; low.fulfill() }
    }

    func testAnAccountProblemIsReportedToTheObserver() async throws {
        let observer = Observer(problem: expectation(description: "account problem"), low: XCTestExpectation(description: "unused"))
        configuration.accountObserver = observer
        api.createJobError = .paymentRequired(nil)
        _ = try? await makeEngine().convert(try request())
        await fulfillment(of: [observer.problem], timeout: 2)
    }

    func testLowCreditsAreReported() async throws {
        let observer = Observer(problem: XCTestExpectation(description: "unused"), low: expectation(description: "low credits"))
        configuration.accountObserver = observer
        configuration.lowCreditThreshold = 10
        api.user = CCUser(id: "1", credits: 4)
        _ = try await makeEngine().convert(try request())
        await fulfillment(of: [observer.low], timeout: 2)
        XCTAssertEqual(observer.lowBalance, 4)
    }

    // MARK: Records

    func testUnreadableRecordsAreRemovedWithTheirJobs() async throws {
        let records = FileStorage(workingDirectory: configuration.workingDirectory, outputDirectory: configuration.outputDirectory,
                                  diskSpaceSafetyMargin: 0).recordsDirectory
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let file = records.appendingPathComponent("old.json")
        try Data(#"{"id": "old", "jobID": "job-old", "phase": "somethingNew"}"#.utf8).write(to: file)

        _ = makeEngine()
        await waitUntil { self.api.deletedJobIDsSnapshot.contains("job-old") }
        XCTAssertTrue(api.deletedJobIDsSnapshot.contains("job-old"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Catalogue

    func testRequestsAreCheckedAgainstTheCatalogueBeforeUploading() async throws {
        configuration.validatesRequests = true
        api.conversions = CatalogTests.rows
        var request = try request("notes.docx")
        request.options = ["pages": .string("1-2")]
        do {
            _ = try await makeEngine().convert(request)
            XCTFail("expected the request to be refused")
        } catch let error as CloudConvertError {
            guard case .invalidRequest(let reason) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(reason.contains("pages"))
        }
        XCTAssertTrue(api.createdSpecifications.isEmpty)
        XCTAssertTrue(transfers.uploads.isEmpty)
    }

    func testAnUnavailableCatalogueChecksNothing() async throws {
        configuration.validatesRequests = true
        api.convertFormatsError = .notConnected
        let result = try await makeEngine().convert(try request())
        XCTAssertEqual(result.files.count, 1)
    }
}

// MARK: - Real API client

final class EngineWithRealAPIClientTests: XCTestCase {

    private var transport: ScriptedTransport!
    private var transfers: FakeTransfers!
    private var configuration: CloudConvertConfiguration!
    private var engine: ConversionEngine!
    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        transport = ScriptedTransport()
        transfers = FakeTransfers()
        let work = TestFiles.temporaryDirectory(), out = TestFiles.temporaryDirectory()
        directories = [work, out]
        configuration = .testing(workingDirectory: work, outputDirectory: out)
        let api = CloudConvertAPI(configuration: configuration, transport: transport, connectivity: AlwaysOnline())
        engine = ConversionEngine(configuration: configuration, api: api, transfers: transfers, connectivity: AlwaysOnline())
    }

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    /// A job shaped like the fixtures: `import` → `convert` → `export`.
    private func specification() throws -> JobSpecification {
        let url = try TestFiles.makeFile(named: "Sample PDF.pdf")
        var builder = JobBuilder(tag: "example-app")
        let input = builder.importUpload(InputFile(url: url), name: "import")
        let converted = builder.convert(input, to: "rtf", name: "convert")
        builder.exportURL(converted, name: "export")
        return try builder.build()
    }

    /// #1: a finished job, as CloudConvert returns it, completes.
    func testFinishedFixtureCompletesWithOneJob() async throws {
        transport.jobBody = try Fixtures.data("job-finished")

        let result = try await engine.run(try specification())

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].filename, "Sample PDF.rtf")
        XCTAssertEqual(result.credits, 4)
        XCTAssertEqual(transport.createsSnapshot, ["job-1"])
        XCTAssertEqual(transfers.uploads.count, 1)
        XCTAssertEqual(transfers.downloads.count, 1)
    }

    /// #3: a file CloudConvert cannot convert is tried once, and not offered for retry.
    func testErrorFixtureIsTriedOnce() async throws {
        transport.jobBody = try Fixtures.data("job-error")

        do {
            _ = try await engine.run(try specification())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .jobFailed(_, let taskName, let code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(taskName, "convert")
            XCTAssertEqual(code, .conversionFailed)
            XCTAssertFalse(error.isRetryable)
        }
        XCTAssertEqual(transport.createsSnapshot.count, 1, "must not rebuild (re-upload, re-bill) the job")
        XCTAssertEqual(transfers.uploads.count, 1)
        await waitUntil { !self.transport.deletesSnapshot.isEmpty }
        XCTAssertEqual(transport.deletesSnapshot, ["job-1"])
    }

    /// #2: a response that cannot be parsed never rebuilds the job.
    func testUndecodableJobIsNotRebuilt() async throws {
        transport.jobBody = Data("<html><body>502 Bad Gateway</body></html>".utf8)

        do {
            _ = try await engine.run(try specification())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .decoding = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(transport.createsSnapshot.count, 1)
        XCTAssertEqual(transfers.uploads.count, 1)
        XCTAssertEqual(transport.polls, configuration.polling.maxConsecutiveFailures, "the poll itself is retried")
        await waitUntil { !self.transport.deletesSnapshot.isEmpty }
        XCTAssertEqual(transport.deletesSnapshot, ["job-1"])
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty)
    }

    /// `POST /jobs` for a job that starts on its own (`import/url`)
    /// is not re-sent after a failure the server may have acted on.
    func testImportURLJobIsNotRepostedAfterTimeout() async throws {
        transport.createHook = { _ in throw URLError(.timedOut) }
        var builder = JobBuilder()
        let input = builder.importURL(URL(string: "https://example.com/book.epub")!, filename: "book.epub", name: "import")
        builder.exportURL(builder.convert(input, to: "mobi", name: "convert"), name: "export")
        do {
            _ = try await engine.run(try builder.build())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .timedOut = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(transport.createsSnapshot.count, 1, "a timed-out POST may have created a billed job")
    }

    /// Upload-only jobs may still be re-sent: a duplicate never runs or bills.
    func testUploadJobIsRepostedAfterTimeout() async throws {
        let failures = Counter()
        transport.createHook = { _ in if failures.next() == 1 { throw URLError(.timedOut) } }
        transport.jobBody = try Fixtures.data("job-finished")
        _ = try await engine.run(try specification())
        XCTAssertEqual(transport.createsSnapshot.count, 2)
    }

    /// #4: cancelling while `POST /jobs` is in flight deletes the job it created.
    func testCancelWhileCreatingJobDeletesTheJob() async throws {
        let gate = Gate()
        transport.createHook = { _ in try await gate.wait() }
        transport.jobBody = try Fixtures.data("job-finished")
        let log = StageLog()

        let handle = engine.start(try specification())
        let observer = Task { for await progress in handle.progress { log.append(progress.stage) } }
        await waitUntil { self.transport.createsSnapshot.count == 1 }
        handle.cancel()

        // The caller does not wait for the server.
        do {
            _ = try await handle.result
            XCTFail("expected cancellation")
        } catch let error as CloudConvertError {
            guard case .cancelled = error else { return XCTFail("unexpected \(error)") }
        }
        await observer.value
        XCTAssertEqual(log.snapshot.last, .cancelled)
        XCTAssertTrue(transport.deletesSnapshot.isEmpty, "the response has not arrived yet")

        // The response arrives after the cancellation: the job is deleted.
        gate.open()
        await waitUntil { !self.transport.deletesSnapshot.isEmpty }
        XCTAssertEqual(transport.deletesSnapshot, ["job-1"])
        XCTAssertTrue(transfers.uploads.isEmpty)
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty)
    }
}

// MARK: - Job rebuilds

final class RebuildPolicyTests: XCTestCase {

    private var api: FakeAPI!
    private var transfers: FakeTransfers!
    private var engine: ConversionEngine!
    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        api = FakeAPI()
        transfers = FakeTransfers()
        let work = TestFiles.temporaryDirectory(), out = TestFiles.temporaryDirectory()
        directories = [work, out]
        let transfers = self.transfers!
        api.serverHasUpload = { transfers.receivedUploadsSnapshot > 0 }
        engine = ConversionEngine(configuration: .testing(workingDirectory: work, outputDirectory: out),
                                  api: api, transfers: transfers, connectivity: AlwaysOnline())
    }

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func request() throws -> ConversionRequest {
        ConversionRequest.convert(try TestFiles.makeFile(named: "book.epub"), to: "mobi")
    }

    func testUndecodablePollFailsOnceAndDeletesJob() async throws {
        api.getJobAlwaysUndecodable = true
        do {
            _ = try await engine.convert(try request())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .decoding = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(api.createdSpecifications.count, 1)
        await waitUntil { !self.api.deletedJobIDsSnapshot.isEmpty }
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-1"])
    }

    func testNullCodeConversionFailureIsNotRebuilt() async throws {
        api.jobStatusScript = [.processing, .error]
        api.failureCode = nil
        do {
            _ = try await engine.convert(try request())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .jobFailed(_, _, .conversionFailed, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertFalse(error.isRetryable)
        }
        XCTAssertEqual(api.createdSpecifications.count, 1)
    }

    func testUnknownFailureCodeIsNotRebuilt() async throws {
        api.jobStatusScript = [.error]
        api.failureCode = "ENGINE_EXPLODED"
        do {
            _ = try await engine.convert(try request())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .jobFailed(_, _, .other("ENGINE_EXPLODED"), _) = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(api.createdSpecifications.count, 1)
    }

    /// Once the input is uploaded, a transport failure while polling must not
    /// start a second (billed) conversion of the same file.
    func testServerErrorsWhilePollingDoNotRebuildJob() async throws {
        api.getJobErrors = Array(repeating: .serverError(status: 503, nil), count: 3)
        do {
            _ = try await engine.convert(try request())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .serverError = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(error.isRetryable, "the app may still offer Try again")
        }
        XCTAssertEqual(api.createdSpecifications.count, 1)
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    /// The same failure before anything was uploaded may rebuild: nothing is billed yet.
    func testServerErrorCreatingJobStillRetries() async throws {
        api.createJobError = .serverError(status: 503, nil)
        do {
            _ = try await engine.convert(try request())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .serverError = error else { return XCTFail("unexpected \(error)") }
        }
    }

    /// A job whose create response lacks upload forms is deleted, not leaked.
    func testJobWithoutUploadFormIsDeleted() async throws {
        api.omitUploadForms = true
        do {
            _ = try await engine.convert(try request())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .uploadFormInvalid = error else { return XCTFail("unexpected \(error)") }
        }
        await waitUntil { self.api.deletedJobIDsSnapshot.count == 1 }
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-1"])
    }

    /// The upload reached storage but its response was lost. The
    /// retry must notice instead of uploading again (the form takes one file,
    /// so a second upload is rejected and would rebuild and re-bill the job).
    func testUploadWhoseResponseWasLostIsNotRepeated() async throws {
        transfers.lostResponses = 1
        transfers.uploadStatuses = [201, 400]   // a second upload to the same form is rejected
        let result = try await engine.convert(try request())
        XCTAssertEqual(result.jobID, "job-1")
        XCTAssertEqual(api.createdSpecifications.count, 1)
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    /// A failure once downloading never rebuilds (the conversion is paid for).
    func testExpiredDownloadLinkDoesNotRebuild() async throws {
        transfers.downloadStatuses = [404]
        do {
            _ = try await engine.convert(try request())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .jobLost = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(api.createdSpecifications.count, 1)
    }

    /// Two inputs with the same file name are both uploaded intact.
    func testSameNamedInputsDoNotOverwriteEachOther() async throws {
        let a = try TestFiles.makeFile(named: "report.docx", bytes: 100)
        let b = try TestFiles.makeFile(named: "report.docx", bytes: 200)
        XCTAssertNotEqual(a, b)
        _ = try await engine.convert(ConversionRequest.merge([a, b], outputFilename: "both.pdf"))
        let sizes = transfers.uploads.map(\.bodySize).sorted()
        XCTAssertEqual(sizes.count, 2)
        XCTAssertEqual(sizes[1] - sizes[0], 100, "each upload carries its own file")
    }

    /// Discarding a conversion that is running is refused.
    func testDiscardingARunningConversionIsRefused() async throws {
        transfers.uploadDelay = 0.3
        let handle = engine.start(try request())
        try await Task.sleep(nanoseconds: 100_000_000)
        await engine.discardPendingConversion(id: handle.id)
        _ = try await handle.result
        XCTAssertTrue(transfers.cancelled.isEmpty)
    }

}

// MARK: - Edge cases

final class EngineEdgeCaseTests: XCTestCase {

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

// MARK: - Output naming

final class OutputNamingTests: XCTestCase {

    /// Many conversions saving `book.pdf` at the same moment each get their own file.
    func testConcurrentFinalizeNeverOverwrites() async throws {
        let work = TestFiles.temporaryDirectory(), out = TestFiles.temporaryDirectory()
        defer { [work, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        let storage = FileStorage(workingDirectory: work, outputDirectory: out, diskSpaceSafetyMargin: 0)
        let sources = try (0..<64).map { index -> URL in
            let url = work.appendingPathComponent("download-\(index)")
            try Data("file \(index)".utf8).write(to: url)
            return url
        }
        let finals = try await withThrowingTaskGroup(of: URL.self) { group -> [URL] in
            for source in sources {
                group.addTask { try storage.finalize(downloadedFile: source, preferredName: "book.pdf") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(finals.map(\.lastPathComponent)).count, 64)
        let contents = Set(try finals.map { try String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(contents.count, 64, "every file kept its own contents")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).count, 64)
    }
}

// MARK: - Background activity

final class SystemBackgroundActivityTests: XCTestCase {
    func testBeginAndEnd() {
        let activity = SystemBackgroundActivity()
        let token = activity.beginActivity(named: "test")
        XCTAssertNotNil(token)
        if let token { activity.endActivity(token) }
    }
}

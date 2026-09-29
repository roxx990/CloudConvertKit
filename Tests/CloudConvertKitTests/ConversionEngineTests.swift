//  End-to-end orchestration tests against the in-memory fakes.
//

import XCTest
@testable import CloudConvertKit

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

    /// Polls `condition` until it holds or `timeout` elapses (for work the
    /// engine performs on detached tasks, such as remote job deletion).
    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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
        try await Task.sleep(nanoseconds: 100_000_000)
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
        transfers.uploadDelay = 0.2
        let queue = ConversionQueue(engine: engine, maxConcurrent: 1)
        let handles = await queue.enqueue([try makeRequest(name: "a.docx"), try makeRequest(name: "b.docx")])
        let started = Date()
        for handle in handles { _ = try await handle.result }
        // Two serial 0.2 s uploads must take at least 0.4 s.
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.35)
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
        transfers.uploadDelay = 0.5
        let handle = engine.start(try makeRequest())
        try await Task.sleep(nanoseconds: 100_000_000)

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

//  Regression tests for the bugs found running against the live CloudConvert
//  API (1.0.1). The fixtures are real `GET /v2/jobs/{id}` responses, and they
//  go through the real `CloudConvertAPI` decoder, not a hand-written fake.
//

import XCTest
@testable import CloudConvertKit

// MARK: - Fixtures

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func job(_ name: String) throws -> CCJob {
        try CCDateDecoding.makeDecoder().decode(CCDataEnvelope<CCJob>.self, from: data(name)).data
    }

    /// The `POST /jobs` response for a job shaped like the fixtures
    /// (`import` → `convert` → `export`), with a fresh upload form.
    static func createdJob(id: String) -> Data {
        let expires = Int(Date().timeIntervalSince1970) + 3600
        return Data("""
        {"data":{"id":"\(id)","tag":"ebook-converter-ios","status":"waiting","created_at":"2026-09-29T15:51:19+00:00",
          "tasks":[
            {"id":"t-export","name":"export","job_id":"\(id)","status":"waiting","code":null,"message":null,"percent":0,
             "operation":"export/url","result":null,"credits":null},
            {"id":"t-convert","name":"convert","job_id":"\(id)","status":"waiting","code":null,"message":null,"percent":0,
             "operation":"convert","engine":null,"result":null,"credits":null},
            {"id":"t-import","name":"import","job_id":"\(id)","status":"waiting","code":null,"message":null,"percent":0,
             "operation":"import/upload","credits":null,
             "result":{"form":{"url":"https://upload.cloudconvert.com/x/","parameters":{"expires":\(expires),"max_file_count":1,"max_file_size":10000000000,"signature":"sig"}}}}]}}
        """.utf8)
    }
}

// MARK: - Scripted HTTP transport

/// Serves `POST /jobs`, `GET /jobs/{id}` and `DELETE /jobs/{id}` so the real
/// `CloudConvertAPI` (auth, retries, decoding, error mapping) is exercised.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    /// Body returned by every `GET /jobs/{id}`, with the fixture's id replaced.
    var jobBody: Data = Data()
    var jobStatus = 200
    /// Awaited while `POST /jobs` is in flight, after the server created the job.
    /// Throwing models URLSession: a cancelled request fails client-side,
    /// although the server has already created the job.
    var createHook: (@Sendable (_ jobID: String) async throws -> Void)?
    private(set) var creates: [String] = []
    private(set) var polls = 0
    private(set) var deletes: [String] = []

    var deletesSnapshot: [String] { lock.lock(); defer { lock.unlock() }; return deletes }
    var createsSnapshot: [String] { lock.lock(); defer { lock.unlock() }; return creates }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let path = request.url?.path ?? ""
        switch request.httpMethod {
        case "POST" where path.hasSuffix("/jobs"):
            lock.lock()
            let id = "job-\(creates.count + 1)"
            creates.append(id)
            let hook = createHook
            lock.unlock()
            if let hook { try await hook(id) }
            return HTTPResponse(status: 201, headers: [:], body: Fixtures.createdJob(id: id))
        case "GET":
            lock.lock()
            polls += 1
            let body = jobBody, status = jobStatus
            lock.unlock()
            return HTTPResponse(status: status, headers: [:], body: body)
        case "DELETE":
            lock.lock(); deletes.append(String(path.split(separator: "/").last ?? "")); lock.unlock()
            return HTTPResponse(status: 204, headers: [:], body: Data())
        default:
            return HTTPResponse(status: 404, headers: [:], body: Data())
        }
    }
}

// MARK: - Model decoding (#1, #3)

final class LiveFixtureDecodingTests: XCTestCase {

    func testFinishedJobFixtureDecodes() throws {
        let job = try Fixtures.job("job-finished")
        XCTAssertEqual(job.status, .finished)
        XCTAssertEqual(job.tasks.count, 3)

        let export = try XCTUnwrap(job.task(named: "export"))
        let files = try XCTUnwrap(export.result?.files)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].filename, "Sample PDF.rtf")
        XCTAssertEqual(files[0].size, 63297)
        XCTAssertEqual(files[0].url.host, "storage.cloudconvert.com")

        // `convert` and `import` list files without a URL: not downloadable,
        // and they must not fail the decode.
        XCTAssertEqual(job.task(named: "convert")?.result?.files, [])
        XCTAssertEqual(job.task(named: "import")?.result?.files, [])
        XCTAssertEqual(job.task(named: "convert")?.credits, 4)
    }

    func testErrorJobFixtureIsANonRetryableConversionFailure() throws {
        let job = try Fixtures.job("job-error")
        XCTAssertEqual(job.status, .error)
        let failed = try XCTUnwrap(job.failedTask)
        XCTAssertEqual(failed.name, "convert", "the root cause, not the export's INPUT_TASK_FAILED")
        XCTAssertNil(failed.code)
        XCTAssertEqual(failed.failureCode, .conversionFailed)
        XCTAssertFalse(TaskFailureCode.conversionFailed.isRetryable)
        XCTAssertEqual(job.task(named: "export")?.failureCode, .inputTaskFailed)
        XCTAssertNil(job.task(named: "import")?.failureCode, "a finished task has no failure code")
    }

    func testTaskWithoutCodeOutsideProcessingStaysUnknownAndIsNotRetried() throws {
        let json = #"{"id":"t","name":"import","operation":"import/upload","status":"error","code":null}"#
        let task = try CCDateDecoding.makeDecoder().decode(CCTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.failureCode, .other("UNKNOWN"))
        XCTAssertFalse(TaskFailureCode.other("SOMETHING_NEW").isRetryable, "unknown codes must not rebuild (and re-bill) the job")
    }

    func testOddTaskResultShapesDoNotFailTheJob() throws {
        let json = """
        {"data":{"id":"j","status":"processing","tasks":[
          {"id":"1","name":"a","operation":"metadata","status":"finished","result":[]},
          {"id":"2","name":"b","operation":"convert","status":"finished","result":{"files":[{"filename":"x"},{"filename":"y","url":"https://s/y"}],"metadata":[]}},
          {"id":"3","name":"c","operation":"export/url","status":"waiting","result":{"files":"soon"}}]}}
        """
        let job = try CCDateDecoding.makeDecoder().decode(CCDataEnvelope<CCJob>.self, from: Data(json.utf8)).data
        XCTAssertNil(job.task(named: "a")?.result)
        XCTAssertEqual(job.task(named: "b")?.result?.files?.map(\.filename), ["y"])
        XCTAssertNil(job.task(named: "b")?.result?.metadata)
        XCTAssertNil(job.task(named: "c")?.result?.files)
    }

    func testConversionFailedMessageIsReadable() {
        let error = CloudConvertError.jobFailed(jobID: "j", taskName: "convert", code: .conversionFailed, message: "Conversion failed")
        XCTAssertFalse(error.userFacingMessage.contains("Conversion failed: Conversion failed"))
        XCTAssertFalse(error.isRetryable)
        XCTAssertFalse(error.requiresNewJob)
    }
}

// MARK: - Engine against the real API client (#1, #2, #3, #4)

final class LiveAPIEngineTests: XCTestCase {

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
        var builder = JobBuilder(tag: "ebook-converter-ios")
        let input = builder.importUpload(InputFile(url: url), name: "import")
        let converted = builder.convert(input, to: "rtf", name: "convert")
        builder.exportURL(converted, name: "export")
        return try builder.build()
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
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

    /// Audit #2: `POST /jobs` for a job that starts on its own (`import/url`)
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

// MARK: - Engine against the fake API (similar issues)

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

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
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

    /// Audit #3: the upload reached storage but its response was lost. The
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

    /// Audit #5: a failure once downloading never rebuilds (the conversion is paid for).
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

    /// Audit #1: two inputs with the same file name are both uploaded intact.
    func testSameNamedInputsDoNotOverwriteEachOther() async throws {
        let a = try TestFiles.makeFile(named: "report.docx", bytes: 100)
        let b = try TestFiles.makeFile(named: "report.docx", bytes: 200)
        XCTAssertNotEqual(a, b)
        _ = try await engine.convert(ConversionRequest.merge([a, b], outputFilename: "both.pdf"))
        let sizes = transfers.uploads.map(\.bodySize).sorted()
        XCTAssertEqual(sizes.count, 2)
        XCTAssertEqual(sizes[1] - sizes[0], 100, "each upload carries its own file")
    }

    /// Audit #7: discarding a conversion that is running is refused.
    func testDiscardingARunningConversionIsRefused() async throws {
        transfers.uploadDelay = 0.3
        let handle = engine.start(try request())
        try await Task.sleep(nanoseconds: 100_000_000)
        await engine.discardPendingConversion(id: handle.id)
        _ = try await handle.result
        XCTAssertTrue(transfers.cancelled.isEmpty)
    }

    func testCancelWhileCreatingJobDeletesTheJob() async throws {
        let gate = Gate()
        api.createJobHook = { _ in try await gate.wait() }
        let handle = engine.start(try request())
        await waitUntil { self.api.createdJobIDs.count == 1 }
        handle.cancel()
        do {
            _ = try await handle.result
            XCTFail("expected cancellation")
        } catch let error as CloudConvertError {
            guard case .cancelled = error else { return XCTFail("unexpected \(error)") }
        }
        gate.open()
        await waitUntil { !self.api.deletedJobIDsSnapshot.isEmpty }
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-1"])
        XCTAssertTrue(transfers.uploads.isEmpty)
    }
}

// MARK: - CancellationShield

final class CancellationShieldTests: XCTestCase {

    func testReturnsValueWhenNotCancelled() async throws {
        let value = try await CancellationShield.run({ 42 }, onAbandoned: { _ in XCTFail("not abandoned") })
        XCTAssertEqual(value, 42)
    }

    func testPropagatesErrors() async {
        do {
            _ = try await CancellationShield.run({ () async throws -> Int in throw CloudConvertError.notConnected },
                                                 onAbandoned: { _ in })
            XCTFail("expected error")
        } catch {
            guard case CloudConvertError.notConnected = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testAlreadyCancelledCallerNeverStartsTheOperation() async {
        let started = Flag()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CancellationShield.run({ started.set(); return 1 }, onAbandoned: { _ in })
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            guard case CloudConvertError.cancelled = error else { return XCTFail("unexpected \(error)") }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(started.isSet)
    }

    func testCancelledCallerHandsTheLateValueToCleanup() async {
        let gate = Gate()
        let abandoned = Flag()
        let task = Task {
            try await CancellationShield.run({ try await gate.wait(); return 7 }, onAbandoned: { value in
                XCTAssertEqual(value, 7); abandoned.set()
            })
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {}
        XCTAssertFalse(abandoned.isSet)
        gate.open()
        let deadline = Date().addingTimeInterval(2)
        while !abandoned.isSet && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(abandoned.isSet)
    }
}

// MARK: - Helpers

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
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
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

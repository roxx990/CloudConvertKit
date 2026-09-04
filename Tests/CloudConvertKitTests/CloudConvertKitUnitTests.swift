//  Focused tests for the pure pieces: retry policy, error classification,
//  model decoding, multipart writing, job builder validation.
//

import XCTest
@testable import CloudConvertKit

final class RetryPolicyTests: XCTestCase {

    func testDelaysGrowAndCap() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 5, multiplier: 2, jitter: 0)
        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4)
        XCTAssertEqual(policy.delay(forAttempt: 4), 5, "capped at maxDelay")
        XCTAssertTrue(policy.shouldRetry(afterAttempt: 4))
        XCTAssertFalse(policy.shouldRetry(afterAttempt: 5))
    }

    func testJitterStaysWithinBounds() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 2, maxDelay: 10, multiplier: 2, jitter: 0.5)
        for _ in 0..<100 {
            let delay = policy.delay(forAttempt: 2) // raw = 4 → 2…4
            XCTAssertGreaterThanOrEqual(delay, 2)
            XCTAssertLessThanOrEqual(delay, 4)
        }
    }

    func testRetryingStopsOnNonRetryableError() async {
        let counter = Counter()
        do {
            let _: Int = try await retrying(policy: .api, phase: .creatingJob, logger: SilentCloudConvertLogger(), label: "t",
                                            operation: { () async throws -> Int in
                counter.increment()
                throw CloudConvertError.validation(nil)
            })
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(counter.value, 1)
        }
    }

    func testRetryingHonoursRetryAfterAndSucceeds() async throws {
        let counter = Counter()
        let started = Date()
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.01, jitter: 0)
        let value: Int = try await retrying(policy: policy, phase: .creatingJob, logger: SilentCloudConvertLogger(), label: "t",
                                            operation: { () async throws -> Int in
            if counter.increment() == 1 { throw CloudConvertError.rateLimited(retryAfter: 0.5) }
            return 42
        })
        XCTAssertEqual(value, 42)
        XCTAssertEqual(counter.value, 2)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.45, "Retry-After must be honoured")
    }

    func testOfflineDoesNotConsumeAttempts() async throws {
        let counter = Counter()
        let waits = Counter()
        let policy = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)
        let value: String = try await retrying(policy: policy, phase: .uploading, logger: SilentCloudConvertLogger(), label: "t",
                                               waitForNetwork: { _ = waits.increment() },
                                               operation: { () async throws -> String in
            if counter.increment() < 3 { throw CloudConvertError.notConnected }
            return "ok"
        })
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(waits.value, 2)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }
}

final class ErrorClassificationTests: XCTestCase {

    func testTaskFailureCodes() {
        XCTAssertEqual(TaskFailureCode(rawCode: "INVALID_CONVERSION_TYPE"), .invalidConversionType)
        XCTAssertEqual(TaskFailureCode(rawCode: "input_task_failed"), .inputTaskFailed)
        XCTAssertEqual(TaskFailureCode(rawCode: "SOMETHING_NEW"), .other("SOMETHING_NEW"))
        XCTAssertFalse(TaskFailureCode.invalidConversionType.isRetryable)
        XCTAssertTrue(TaskFailureCode.timeout.isRetryable)
    }

    func testURLErrorMapping() {
        let offline = CloudConvertError.wrap(URLError(.notConnectedToInternet), phase: .uploading)
        XCTAssertTrue(offline.isConnectivityRelated)
        XCTAssertTrue(offline.isRetryable)

        let cancelled = CloudConvertError.wrap(URLError(.cancelled), phase: .uploading)
        if case .cancelled = cancelled {} else { XCTFail("expected cancelled") }

        let timeout = CloudConvertError.wrap(URLError(.timedOut), phase: .downloading)
        if case .timedOut(let phase) = timeout { XCTAssertEqual(phase, .downloading) } else { XCTFail("expected timedOut") }
    }

    func testHTTPMapping() {
        let response = HTTPResponse(status: 429, headers: ["Retry-After": "7"], body: Data())
        let error = HTTPErrorMapper.error(for: response)
        XCTAssertEqual(error.mandatoryRetryDelay, 7)
        XCTAssertTrue(error.isRetryable)

        let validation = HTTPErrorMapper.error(for: HTTPResponse(status: 422, headers: [:],
            body: Data(#"{"message":"Invalid","code":"INVALID_DATA","errors":{"tasks.convert.output_format":["unsupported"]}}"#.utf8)))
        XCTAssertFalse(validation.isRetryable)
        XCTAssertTrue(validation.userFacingMessage.contains("unsupported"))

        XCTAssertTrue(HTTPErrorMapper.error(for: HTTPResponse(status: 503, headers: [:], body: Data())).isRetryable)
        XCTAssertFalse(HTTPErrorMapper.error(for: HTTPResponse(status: 401, headers: [:], body: Data())).isRetryable)
    }

    func testUserMessagesNeverLeakURLs() {
        let error = CloudConvertError.downloadFailed(url: URL(string: "https://storage.cloudconvert.com/secret")!, status: 500, description: nil)
        XCTAssertFalse(error.userFacingMessage.contains("cloudconvert.com"))
    }
}

final class ModelDecodingTests: XCTestCase {

    func testJobWithUploadFormDecodes() throws {
        let json = """
        {"data":{"id":"abc","tag":"t","status":"waiting","created_at":"2026-09-04T10:00:00.000000Z",
          "tasks":[{"id":"1","name":"import-1","operation":"import/upload","status":"waiting",
                    "result":{"form":{"url":"https://upload.cloudconvert.com/x/","parameters":{"signature":"s","expires":1893456000,"max_file_size":"10000000000","max_file_count":1}}}},
                   {"id":"2","name":"export-1","operation":"export/url","status":"waiting","percent":"12.5"}]}}
        """
        let job = try CCDateDecoding.makeDecoder().decode(CCDataEnvelope<CCJob>.self, from: Data(json.utf8)).data
        XCTAssertEqual(job.id, "abc")
        XCTAssertEqual(job.status, .waiting)
        XCTAssertNotNil(job.createdAt)
        let form = try XCTUnwrap(job.task(named: "import-1")?.result?.form)
        XCTAssertEqual(form.url.absoluteString, "https://upload.cloudconvert.com/x/")
        XCTAssertEqual(form.parameters.map(\.key), ["expires", "max_file_count", "max_file_size", "signature"], "signature must be last")
        XCTAssertEqual(form.maxFileSize, 10_000_000_000)
        XCTAssertFalse(form.isExpired)
        XCTAssertEqual(job.task(named: "export-1")?.percent, 12.5)
    }

    func testUnknownStatusDecodesAsProcessing() throws {
        let json = #"{"data":{"id":"abc","status":"brand_new","tasks":[]}}"#
        let job = try CCDateDecoding.makeDecoder().decode(CCDataEnvelope<CCJob>.self, from: Data(json.utf8)).data
        XCTAssertEqual(job.status, .processing)
    }

    func testFailedTaskPrefersRootCause() throws {
        let json = """
        {"data":{"id":"j","status":"error","tasks":[
          {"id":"1","name":"export-1","operation":"export/url","status":"error","code":"INPUT_TASK_FAILED","message":"Input task has failed"},
          {"id":"2","name":"process-1","operation":"convert","status":"error","code":"CONVERSION_FAILED","message":"boom"}]}}
        """
        let job = try CCDateDecoding.makeDecoder().decode(CCDataEnvelope<CCJob>.self, from: Data(json.utf8)).data
        XCTAssertEqual(job.failedTask?.name, "process-1")
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = ["a": 1, "b": 2.5, "c": true, "d": nil, "e": ["x", 2], "f": ["k": "v"]]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["e"]?[1]?.intValue, 2)
    }
}

final class MultipartFormWriterTests: XCTestCase {

    func testBodyLayout() throws {
        let file = try TestFiles.makeFile(named: "in.bin", bytes: 3 * 1024 * 1024 + 17)
        let form = CCUploadForm(url: URL(string: "https://upload.example/")!, parameters: [("expires", "1"), ("signature", "sig")])
        let destination = TestFiles.temporaryDirectory().appendingPathComponent("body.multipart")

        let body = try MultipartFormWriter.writeUploadBody(form: form, file: file, filename: "we\"ird\r\n.bin", to: destination)
        let data = try Data(contentsOf: destination)
        XCTAssertEqual(Int64(data.count), body.contentLength)
        XCTAssertTrue(body.contentType.hasPrefix("multipart/form-data; boundary="))

        let boundary = body.contentType.replacingOccurrences(of: "multipart/form-data; boundary=", with: "")
        let text = String(decoding: data.prefix(400), as: UTF8.self)
        XCTAssertTrue(text.contains("--\(boundary)\r\nContent-Disposition: form-data; name=\"expires\"\r\n\r\n1\r\n"))
        XCTAssertTrue(text.contains("name=\"signature\"\r\n\r\nsig\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"we%22ird.bin\""), "quotes and CRLF are neutralised")
        XCTAssertTrue(String(decoding: data.suffix(boundary.count + 8), as: UTF8.self).hasSuffix("--\(boundary)--\r\n"))

        // The signature field must precede the file field.
        let signatureRange = try XCTUnwrap(data.range(of: Data("name=\"signature\"".utf8)))
        let fileRange = try XCTUnwrap(data.range(of: Data("name=\"file\"".utf8)))
        XCTAssertLessThan(signatureRange.lowerBound, fileRange.lowerBound)
    }
}

final class JobBuilderTests: XCTestCase {

    func testBuilderRejectsMissingExport() {
        var builder = JobBuilder()
        _ = builder.importUpload(InputFile(url: URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertThrowsError(try builder.build())
    }

    func testBuilderRejectsInvalidNames() {
        var builder = JobBuilder()
        let file = builder.importUpload(InputFile(url: URL(fileURLWithPath: "/tmp/a.txt")), name: "bad name!")
        let pdf = builder.convert(file, to: "pdf")
        builder.exportURL(pdf)
        XCTAssertThrowsError(try builder.build())
    }

    func testBuilderAppliesDefaultTimeoutToProcessingTasksOnly() throws {
        var builder = JobBuilder(defaultTimeout: 300)
        let file = builder.importUpload(InputFile(url: URL(fileURLWithPath: "/tmp/a.txt")))
        let thumb = builder.thumbnail(file, outputFormat: "png", width: 300, fit: "max")
        builder.exportURL(thumb)
        let spec = try builder.build()
        XCTAssertNil(spec.task(named: file.name)?.options["timeout"])
        XCTAssertEqual(spec.task(named: thumb.name)?.options["timeout"], 300)
        XCTAssertEqual(spec.task(named: thumb.name)?.options["width"], 300)
        XCTAssertNil(spec.task(named: "export")?.options["timeout"])
    }

    func testFilenameSanitisation() {
        XCTAssertEqual(FileStorage.sanitizedFilename("a/b\\c:d\"e.pdf"), "a-b-c-d'e.pdf")
        XCTAssertEqual(FileStorage.sanitizedFilename(".hidden"), "_hidden")
        XCTAssertEqual(FileStorage.sanitizedFilename("   "), "file")
        XCTAssertEqual(FileStorage.outputName(for: "My Report.docx", outputFormat: "PDF"), "My Report.pdf")
    }
}

final class APIModelTests: XCTestCase {

    func testErrorPayloadDecodesMixedErrorShapes() throws {
        let json = #"{"message":"Invalid data","code":"INVALID_DATA","errors":{"tasks.convert-1.output_format":["The output format is invalid."],"tag":"too long","nested":{"a":1}}}"#
        let payload = try JSONDecoder().decode(APIErrorPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.code, "INVALID_DATA")
        XCTAssertEqual(payload.errors?["tag"], ["too long"])
        XCTAssertEqual(payload.errors?["nested"], ["1"])
        XCTAssertTrue(payload.flattenedErrors?.contains("output format is invalid") == true)

        let bare = try JSONDecoder().decode(APIErrorPayload.self, from: Data(#"{"message":"Nope","errors":["x","y"]}"#.utf8))
        XCTAssertEqual(bare.message, "Nope")
        XCTAssertEqual(bare.errors?["errors"], ["x", "y"])
    }

    func testUserDecodes() throws {
        let json = #"{"data":{"id":1,"username":"Username","email":"me@example.com","created_at":"2018-12-01T22:26:29+00:00","credits":4434,"links":{"self":"https://api.cloudconvert.com/v2/users/1"}}}"#
        let user = try CCDateDecoding.makeDecoder().decode(CCDataEnvelope<CCUser>.self, from: Data(json.utf8)).data
        XCTAssertEqual(user.id, "1")
        XCTAssertEqual(user.credits, 4434)
        XCTAssertNotNil(user.createdAt)
    }

    func testJobPageDecodes() throws {
        let json = #"{"data":[{"id":"a","status":"finished","tasks":[]},{"id":"b","status":"error"}],"meta":{"current_page":1,"last_page":"3","per_page":100,"total":250}}"#
        let page = try CCDateDecoding.makeDecoder().decode(CCPage<CCJob>.self, from: Data(json.utf8))
        XCTAssertEqual(page.data.map(\.id), ["a", "b"])
        XCTAssertEqual(page.meta?.lastPage, 3)
        XCTAssertTrue(page.meta?.hasMorePages == true)
    }

    func testOperationsDecodeLeniently() throws {
        let json = """
        {"data":[
          {"operation":"convert","input_format":"heic","output_format":"jpg","engine":"imagemagick","engine_versions":["7.1",{"version":"6.9","default":true}],"credits":1,"deprecated":0,
           "options":[{"name":"quality","type":"integer","default":"75","possible_values":null,"description":"JPEG quality"}]},
          {"operation":"convert","input_format":"pdf","output_format":"docx","engine":"office","credits":"2","experimental":"true"}
        ]}
        """
        let operations = try CCDateDecoding.makeDecoder().decode(CCDataEnvelope<[CCOperation]>.self, from: Data(json.utf8)).data
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[0].deprecated, false)
        XCTAssertEqual(operations[0].engineVersions?.count, 2)
        XCTAssertEqual(operations[0].options?.first?.name, "quality")
        XCTAssertEqual(operations[0].options?.first?.default?.intValue, 75)
        XCTAssertEqual(operations[1].credits, 2)
        XCTAssertEqual(operations[1].experimental, true)
    }

    func testJobsFilterQuery() {
        let items = JobsFilter(status: .finished, tag: "pdf-app", includeTasks: true, page: 2, perPage: 50).queryItems
        XCTAssertEqual(items.map(\.name), ["filter[status]", "filter[tag]", "include", "page", "per_page"])
        XCTAssertEqual(items.map(\.value), ["finished", "pdf-app", "tasks", "2", "50"])
    }
}

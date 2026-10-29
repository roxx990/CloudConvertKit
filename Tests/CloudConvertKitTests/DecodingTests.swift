//  Decoding what the API sends: lenient models, real job responses, URLs.
//

import XCTest
@testable import CloudConvertKit
import CloudConvertKitUI

// MARK: - Models

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

// MARK: - Real responses

final class FixtureDecodingTests: XCTestCase {

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

// MARK: - URLs

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

//  The error taxonomy: classification, categories, user-facing text and
//  its localization.
//

import XCTest
@testable import CloudConvertKit

// MARK: - Classification

final class ErrorClassificationTests: XCTestCase {

    func testTaskFailureCodes() {
        XCTAssertEqual(TaskFailureCode(rawCode: "INVALID_CONVERSION_TYPE"), .invalidConversionType)
        XCTAssertEqual(TaskFailureCode(rawCode: "input_task_failed"), .inputTaskFailed)
        XCTAssertEqual(TaskFailureCode(rawCode: "EXPORT_FAILED"), .exportFailed)
        XCTAssertEqual(TaskFailureCode(rawCode: "UNKNOWN_ERROR"), .unknownError)
        XCTAssertEqual(TaskFailureCode(rawCode: "SOMETHING_NEW"), .other("SOMETHING_NEW"))
        XCTAssertTrue(TaskFailureCode.timeout.isRetryable)
        for code: TaskFailureCode in [.invalidConversionType, .conversionFailed, .exportFailed, .unknownError, .other("SOMETHING_NEW")] {
            XCTAssertFalse(code.isRetryable, "\(code) would rebuild, and bill, the job again")
        }
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
        // The server's text stays in the payload, for logs; the user never sees it.
        XCTAssertFalse(validation.userFacingMessage.contains("unsupported"))
        guard case .validation(let payload) = validation else { return XCTFail("expected validation") }
        XCTAssertTrue(payload?.flattenedErrors?.contains("unsupported") == true)

        XCTAssertTrue(HTTPErrorMapper.error(for: HTTPResponse(status: 503, headers: [:], body: Data())).isRetryable)
        XCTAssertFalse(HTTPErrorMapper.error(for: HTTPResponse(status: 401, headers: [:], body: Data())).isRetryable)
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
}

// MARK: - Presentation

final class ErrorPresentationTests: XCTestCase {

    override func tearDown() {
        CloudConvertLocalization.setProvider(nil)
        super.tearDown()
    }

    func testAccountProblemsAreTheirOwnCategory() {
        XCTAssertEqual(CloudConvertError.paymentRequired(nil).category, .account)
        XCTAssertEqual(CloudConvertError.unauthorized(nil).category, .account)
        XCTAssertEqual(CloudConvertError.jobFailed(jobID: "j", taskName: nil, code: .insufficientCredits, message: nil).category, .account)
        XCTAssertTrue(CloudConvertError.forbidden(nil).isAccountProblem)
    }

    func testFileUnsupportedAndPausedFailuresAreToldApart() {
        XCTAssertEqual(CloudConvertError.jobFailed(jobID: "j", taskName: nil, code: .openFailed, message: nil).category, .input)
        XCTAssertEqual(CloudConvertError.jobFailed(jobID: "j", taskName: nil, code: .invalidConversionType, message: nil).category, .unsupported)
        XCTAssertEqual(CloudConvertError.jobFailed(jobID: "j", taskName: nil, code: .exportFailed, message: nil).category, .unsupported)
        XCTAssertEqual(CloudConvertError.timedOut(phase: .waitingForNetwork).category, .paused)
        XCTAssertEqual(CloudConvertError.jobTimedOut(jobID: "j").category, .paused)
        XCTAssertEqual(CloudConvertError.notConnected.category, .connectivity)
        XCTAssertEqual(CloudConvertError.serverError(status: 503, nil).category, .service)
        XCTAssertEqual(CloudConvertError.insufficientDiskSpace(required: 1, available: 0).category, .device)
    }

    func testAnalyticsCodesNameTheCase() {
        XCTAssertEqual(CloudConvertError.jobFailed(jobID: "j", taskName: nil, code: .exportFailed, message: nil).analyticsCode,
                       "job_failed_exportFailed")
    }

    func testUserMessagesNeverLeakURLs() {
        let error = CloudConvertError.downloadFailed(url: URL(string: "https://storage.cloudconvert.com/secret")!, status: 500, description: nil)
        XCTAssertFalse(error.userFacingMessage.contains("cloudconvert.com"))
    }

    func testInvalidRequestKeepsDeveloperTextOutOfTheMessage() {
        let error = CloudConvertError.invalidRequest(reason: "Task 'x' references unknown input 'y'.")
        XCTAssertFalse(error.userFacingMessage.contains("unknown input"))
    }

    func testConversionFailedMessageIsReadable() {
        let error = CloudConvertError.jobFailed(jobID: "j", taskName: "convert", code: .conversionFailed, message: "Conversion failed")
        XCTAssertFalse(error.userFacingMessage.contains("Conversion failed: Conversion failed"))
        XCTAssertFalse(error.isRetryable)
        XCTAssertFalse(error.requiresNewJob)
    }

    func testPausedConversionsSuggestTryingAgain() {
        XCTAssertNotNil(CloudConvertError.jobTimedOut(jobID: "j").recoverySuggestion)
        XCTAssertNil(CloudConvertError.emptyFile(URL(fileURLWithPath: "/a")).recoverySuggestion)
    }

    // MARK: Localization

    func testMessagesGoThroughTheLocalizationProvider() {
        CloudConvertLocalization.setProvider { key, english in key == "cloudconvert.error.notConnected" ? "Hors ligne" : english }
        XCTAssertEqual(CloudConvertError.notConnected.userFacingMessage, "Hors ligne")
        XCTAssertEqual(CloudConvertError.notConnected.messageKey, "cloudconvert.error.notConnected")
        XCTAssertEqual(CloudConvertError.network(code: .unknown, description: "x").userFacingMessage,
                       "A network error interrupted the conversion. Please try again.")
    }

    func testArgumentsAreFormattedIntoTheTranslation() {
        CloudConvertLocalization.setProvider { key, english in key == "cloudconvert.error.fileTooLarge" ? "Trop grand : %@ sur %@" : english }
        let message = CloudConvertError.fileTooLarge(URL(fileURLWithPath: "/a"), size: 2_000_000, limit: 1_000_000).userFacingMessage
        XCTAssertTrue(message.hasPrefix("Trop grand : "))
        XCTAssertFalse(message.contains("%@"))
    }

    func testStagesAreLocalizedToo() {
        CloudConvertLocalization.setProvider { key, english in key == "cloudconvert.stage.retrying" ? "Nouvel essai (%d)" : english }
        let progress = ConversionProgress(conversionID: "c", stage: .retrying(attempt: 2, delay: 1, scope: .job, reason: "x"), fractionCompleted: 0)
        XCTAssertEqual(progress.localizedStageDescription, "Nouvel essai (2)")
    }
}

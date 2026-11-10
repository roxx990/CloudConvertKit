//  What a failure leads to at each step: the same job tried again, a new
//  job, or the end. A new job uploads, and bills, the file again, so the
//  engine starts one only while nothing can have been billed.
//

import XCTest
@testable import CloudConvertKit

final class FailureHandlingTests: EngineTestCase {

    // MARK: Ended without a new job

    /// A task that failed for a reason a new job won't change (a known code,
    /// no code at all, or one the kit doesn't know) is tried once.
    func testAFailedTaskIsNotRetried() async throws {
        let cases: [(code: String?, expected: TaskFailureCode)] = [
            ("INVALID_CONVERSION_TYPE", .invalidConversionType),
            (nil, .conversionFailed),
            ("ENGINE_EXPLODED", .other("ENGINE_EXPLODED")),
        ]
        api.jobStatusScript = [.error]
        for (index, (code, expected)) in cases.enumerated() {
            api.failureCode = code
            do {
                _ = try await engine.convert(try request())
                XCTFail("\(expected): expected failure")
            } catch let error as CloudConvertError {
                guard case .jobFailed(_, _, let failure, _) = error else { return XCTFail("\(expected): unexpected \(error)") }
                XCTAssertEqual(failure, expected)
                XCTAssertFalse(error.isRetryable)
            }
            let jobID = "job-\(index + 1)"
            XCTAssertEqual(api.createdJobIDs.last, jobID, "\(expected): the job must not be rebuilt")
            XCTAssertEqual(api.createdJobIDs.count, index + 1, "\(expected): the job must not be rebuilt")
            await waitUntil { self.api.deletedJobIDsSnapshot.contains(jobID) }
            XCTAssertTrue(api.deletedJobIDsSnapshot.contains(jobID), "\(expected): the failed job is deleted")
        }
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

    // MARK: The same job tried again

    func testUploadServerErrorRetriesSameJobAndReportsRetrying() async throws {
        transfers.uploadStatuses = [503, 201]
        let log = StageLog()

        let result = try await engine.convert(try request()) { log.append($0.stage) }

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

    func testAFreshFormIsUsedWhateverTheDeviceClockSays() async throws {
        api.formExpiresIn = -3600                     // by the device clock, every form expired an hour ago

        let result = try await engine.convert(try request())

        XCTAssertEqual(result.jobID, "job-1")
        XCTAssertEqual(api.createdSpecifications.count, 1)
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

    // MARK: A new job

    func testTransientJobFailureRebuildsJobOnce() async throws {
        // First job errors with a retryable code, second succeeds.
        api.jobStatusScripts = [[.error], [.finished]]
        api.failureCode = "TIMEOUT"

        let result = try await engine.convert(try request())

        XCTAssertEqual(result.jobID, "job-2")
        XCTAssertEqual(api.createdSpecifications.count, 2)
        XCTAssertEqual(transfers.uploads.count, 2, "a rebuilt job uploads again")
    }

    func testUploadRejectedByStorageRebuildsJob() async throws {
        transfers.uploadStatuses = [403, 201]   // expired policy → fresh job → success
        let result = try await engine.convert(try request())
        XCTAssertEqual(result.jobID, "job-2")
        XCTAssertEqual(api.createdSpecifications.count, 2)
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

    /// The "did the upload arrive?" check finding the job gone (404) rebuilds
    /// the job, instead of failing with `.notFound`.
    func testJobGoneDuringUploadRetriesIsRebuilt() async throws {
        transfers.lostResponses = 1                  // the first upload's response is lost
        api.getJobErrors = [.notFound(nil)]          // and the job is gone when asked

        let result = try await engine.convert(try request())

        XCTAssertEqual(result.jobID, "job-2")
        XCTAssertEqual(api.createdSpecifications.count, 2)
    }

    /// A form a previous launch received that the device clock says has
    /// expired leads to a new job.
    func testAnOldFormThatLooksExpiredRebuildsTheJob() async throws {
        _ = try await seedPreviousLaunch(phase: .uploading, configuration: configuration, api: api)
        api.formExpiresIn = -3600
        api.jobStatusScript = [.waiting, .processing, .finished]

        let handles = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-1", "a new job")
        XCTAssertEqual(transfers.uploads.count, 1)
    }
}

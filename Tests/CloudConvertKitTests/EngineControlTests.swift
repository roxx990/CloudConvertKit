//  What the app sets and hears: concurrency limits, keyed requests, checks
//  against the catalogue, account problems, and records the kit can't read.
//

import XCTest
@testable import CloudConvertKit

final class EngineControlTests: EngineTestCase {

    // MARK: Limits

    func testQueueLimitsConcurrency() async throws {
        transfers.uploadDelay = 0.05
        let queue = ConversionQueue(engine: engine, maxConcurrent: 1)
        let handles = await queue.enqueue([try request("a.docx"), try request("b.docx")])
        for handle in handles { _ = try await handle.result }
        XCTAssertEqual(transfers.maxConcurrentUploads, 1)
        XCTAssertEqual(transfers.uploads.count, 2)
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

    /// The check runs after `convert` returns, while the engine lives.
    func testLowCreditsAreReported() async throws {
        let observer = Observer(problem: XCTestExpectation(description: "unused"), low: expectation(description: "low credits"))
        configuration.accountObserver = observer
        configuration.lowCreditThreshold = 10
        api.user = CCUser(id: "1", credits: 4)
        _ = try await engine.convert(try request())
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
}

//  Cancelling at every step: it ends with `.cancelled`, deletes the job and
//  keeps nothing to resume.
//

import XCTest
@testable import CloudConvertKit

final class CancellationTests: EngineTestCase {

    func testCancellationDuringUploadCleansUp() async throws {
        transfers.uploadDelay = 1
        let request = try request()
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

    func testCancellationDuringRebuildDelayCleansUp() async throws {
        configuration.jobRetryPolicy = RetryPolicy(maxAttempts: 2, baseDelay: 1, maxDelay: 1, jitter: 0)
        engine = makeEngine(connectivity: AlwaysOnline())
        api.jobStatusScript = [.error]
        api.failureCode = "TIMEOUT"
        let log = StageLog()

        let handle = engine.start(try request())
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

    func testAnInfiniteRetryAfterWaitsInsteadOfTrapping() async throws {
        api.createJobError = .rateLimited(retryAfter: .infinity)
        let engine = self.engine, conversionRequest = try request()
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

    /// The user cancels while a status check finds the device offline, and
    /// the wait for the network then gives up: a cancellation, not kept.
    func testCancellingDuringAnOfflinePollIsACancellation() async throws {
        let engine = makeEngine(connectivity: DroppedNetwork())
        let handleBox = HandleBox(), calls = Counter()
        api.getJobHook = { _ in
            if calls.next() == 1 {
                handleBox.handle?.cancel()
                throw CloudConvertError.notConnected
            }
        }
        let handle = engine.start(try request())
        handleBox.handle = handle

        do {
            _ = try await handle.result
            XCTFail("expected an error")
        } catch let error as CloudConvertError {
            XCTAssertTrue(error.isCancellation, "cancelled by the user, ended with \(error)")
        }
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty, "a conversion the user cancelled was kept: \(pending.map(\.id))")
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

    // MARK: Waiting for a slot

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
}

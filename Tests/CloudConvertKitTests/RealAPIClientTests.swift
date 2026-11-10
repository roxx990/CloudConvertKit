//  The engine with the real `CloudConvertAPI` (authorization, retries,
//  decoding, error mapping) over a scripted transport serving the real job
//  responses in Fixtures/.
//

import XCTest
@testable import CloudConvertKit

final class RealAPIClientTests: XCTestCase {

    private var transport: ScriptedTransport!
    private var transfers: FakeFileTransfers!
    private var configuration: CloudConvertConfiguration!
    private var engine: ConversionEngine!
    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        transport = ScriptedTransport()
        transfers = FakeFileTransfers()
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

    /// A finished job, as CloudConvert returns it, completes.
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

    /// A file CloudConvert cannot convert is tried once, and not offered for retry.
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

    /// A response that cannot be parsed never rebuilds the job.
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

    /// Cancelling while `POST /jobs` is in flight deletes the job it created.
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

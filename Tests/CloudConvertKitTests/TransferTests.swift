//  Background transfers: the session handoff, cancellation, and
//  re-attaching to transfers a previous launch started.
//

import XCTest
import Network
@testable import CloudConvertKit
import CloudConvertKitUI

// MARK: - Transfer manager

final class BackgroundTransferManagerTests: XCTestCase {

    /// Holds every request open until it is cancelled, like a long upload.
    private final class StalledProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    private func makeManager() -> BackgroundTransferManager {
        let manager = BackgroundTransferManager(identifier: "tests.\(UUID().uuidString)",
                                                registryDirectory: TestFiles.temporaryDirectory(),
                                                usesBackgroundSession: false,
                                                logger: SilentCloudConvertLogger())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StalledProtocol.self]
        manager.session = URLSession(configuration: configuration, delegate: manager, delegateQueue: nil)
        return manager
    }

    /// Starts an upload and returns its waiter once the task is in flight.
    private func startUpload(on manager: BackgroundTransferManager, id: String) async throws -> (Task<TransferOutcome, Error>, URLSessionTask) {
        let body = try TestFiles.makeFile(named: "body.bin")
        var request = URLRequest(url: URL(string: "https://upload.example/form")!)
        request.httpMethod = "POST"
        let waiter = Task { try await manager.upload(id: id, request: request, bodyFile: body) { _ in } }
        for _ in 0..<300 {
            if let task = await manager.session.allTasks.first(where: { $0.taskDescription == id }) { return (waiter, task) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CloudConvertError.transferLost(id: id)
    }

    /// #4: iOS cancels background transfers when the user force-quits the
    /// app. That is a lost transfer, to start again, not a user cancellation
    /// (which would delete the paid job).
    func testCancellationByTheSystemIsALostTransfer() async throws {
        let manager = makeManager()
        let (waiter, task) = try await startUpload(on: manager, id: "cancelled-by-the-system")

        task.cancel()

        do {
            _ = try await waiter.value
            XCTFail("expected an error")
        } catch CloudConvertError.transferLost(let id) {
            XCTAssertEqual(id, "cancelled-by-the-system")
        } catch {
            XCTFail("expected transferLost, got \(error)")
        }
    }

    /// #4: a cancellation the engine asked for is still a cancellation.
    func testCancellationTheEngineAskedForIsACancellation() async throws {
        let manager = makeManager()
        let (waiter, _) = try await startUpload(on: manager, id: "cancelled-by-the-user")

        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("expected an error")
        } catch CloudConvertError.cancelled {
        } catch {
            XCTFail("expected cancelled, got \(error)")
        }
    }

    /// #7: engines created at the same time for one identifier share one
    /// manager, so one background session.
    func testConcurrentCreationMakesOneManagerPerIdentifier() async {
        let identifier = "tests.\(UUID().uuidString)"
        let directory = TestFiles.temporaryDirectory()
        let made = Counter()
        let managers = await withTaskGroup(of: ObjectIdentifier.self) { group -> Set<ObjectIdentifier> in
            for _ in 0..<16 {
                group.addTask {
                    ObjectIdentifier(BackgroundTransferManager.shared(for: identifier) {
                        _ = made.next()
                        Thread.sleep(forTimeInterval: 0.01)     // widen the window a check-then-create loses
                        return BackgroundTransferManager(identifier: identifier, registryDirectory: directory,
                                                         usesBackgroundSession: false, logger: SilentCloudConvertLogger())
                    })
                }
            }
            return await group.reduce(into: []) { $0.insert($1) }
        }
        XCTAssertEqual(managers.count, 1)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(BackgroundTransferManager.shared(for: identifier).map(ObjectIdentifier.init), managers.first)
    }
}

// MARK: - Background handoff

final class BackgroundHandoffTests: XCTestCase {

    private func makeManager(_ identifier: String) -> BackgroundTransferManager {
        BackgroundTransferManager(identifier: identifier, registryDirectory: TestFiles.temporaryDirectory(),
                                  usesBackgroundSession: false, logger: SilentCloudConvertLogger())
    }

    func testAHandlerThatArrivesBeforeItsManagerIsKept() {
        let identifier = "tests.handoff.\(UUID().uuidString)"
        let called = expectation(description: "completion handler")
        BackgroundTransferManager.handleEventsForBackgroundURLSession(identifier: identifier) { called.fulfill() }

        let manager = makeManager(identifier)
        manager.urlSessionDidFinishEvents(forBackgroundURLSession: manager.session)
        wait(for: [called], timeout: 2)
    }

    func testAHandlerThatArrivesJustAfterTheEventsIsCalledAtOnce() {
        let identifier = "tests.handoff.\(UUID().uuidString)"
        let manager = makeManager(identifier)
        manager.urlSessionDidFinishEvents(forBackgroundURLSession: manager.session)

        let called = expectation(description: "completion handler")
        BackgroundTransferManager.handleEventsForBackgroundURLSession(identifier: identifier) { called.fulfill() }
        wait(for: [called], timeout: 2)
    }

    func testAHandlerWaitsForEventsThatAreStillComing() {
        let identifier = "tests.handoff.\(UUID().uuidString)"
        let manager = makeManager(identifier)
        let called = expectation(description: "completion handler")
        called.isInverted = true
        manager.setBackgroundCompletionHandler { called.fulfill() }
        wait(for: [called], timeout: 0.1)
    }
}

// MARK: - Cancellation

final class TransferCancellationTests: XCTestCase {

    /// Upload tasks whose completion is delivered the moment they are
    /// cancelled: the delegate finishes the transfer before its waiter
    /// has installed its continuation.
    final class InstantCancelSession: URLSession, @unchecked Sendable {
        weak var manager: BackgroundTransferManager?
        override func uploadTask(with request: URLRequest, fromFile fileURL: URL) -> URLSessionUploadTask {
            let task = InstantCancelTask()
            task.onCancel = { [weak self] cancelled in
                guard let self, let manager = self.manager else { return }
                manager.urlSession(self, task: cancelled, didCompleteWithError: URLError(.cancelled))
            }
            return task
        }
    }

    final class InstantCancelTask: URLSessionUploadTask, @unchecked Sendable {
        var onCancel: ((URLSessionTask) -> Void)?
        private var storedDescription: String?
        override var taskDescription: String? {
            get { storedDescription }
            set { storedDescription = newValue }
        }
        override var response: URLResponse? { nil }
        override func resume() {}
        override func cancel() { onCancel?(self) }
    }

    func testCancellationJustAsATransferStartsIsACancellation() async throws {
        let manager = BackgroundTransferManager(identifier: "tests.\(UUID().uuidString)",
                                                registryDirectory: TestFiles.temporaryDirectory(),
                                                usesBackgroundSession: false,
                                                logger: SilentCloudConvertLogger())
        let session = InstantCancelSession()
        session.manager = manager
        manager.session = session
        let body = try TestFiles.makeFile(named: "body.bin")
        var request = URLRequest(url: URL(string: "https://upload.example/form")!)
        request.httpMethod = "POST"

        let waiter = Task { () async throws -> TransferOutcome in
            withUnsafeCurrentTask { $0?.cancel() }        // the caller is cancelled just as the upload starts
            return try await manager.upload(id: "upload-1", request: request, bodyFile: body) { _ in }
        }

        do {
            _ = try await waiter.value
            XCTFail("expected an error")
        } catch CloudConvertError.cancelled {
        } catch {
            XCTFail("a cancellation the caller asked for came back as \(error)")
        }
    }
}

// MARK: - Re-attaching

final class ReattachTests: XCTestCase {

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

    /// The app died mid-upload; the upload of `import-1` was still running.
    private func seedInterruptedUpload() async throws {
        _ = try await seedPreviousLaunch(phase: .uploading, configuration: configuration, api: api) {
            $0.uploadTransfers = ["import-1": "upload-from-last-launch"]
        }
    }

    /// #3: a re-attached upload that storage answered with a 503 is retried
    /// against the same form, as a fresh one is, instead of rebuilding the job.
    func testReattachedUploadAnswered503IsRetriedAgainstTheSameForm() async throws {
        try await seedInterruptedUpload()
        transfers.reattach = { _ in outcome(503) }
        api.jobStatusScript = [.waiting, .waiting, .processing, .finished]

        let handles = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-9")
        XCTAssertTrue(api.createdSpecifications.isEmpty, "the job is not rebuilt")
        XCTAssertEqual(transfers.reattached, ["upload-from-last-launch"])
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    /// #3: a re-attached upload whose connection dropped waits for the
    /// network and is retried, instead of failing the conversion.
    func testReattachedUploadThatLostTheNetworkIsRetried() async throws {
        try await seedInterruptedUpload()
        transfers.reattach = { _ in throw CloudConvertError.network(code: .networkConnectionLost, description: "lost") }
        api.jobStatusScript = [.waiting, .waiting, .processing, .finished]

        let handles = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-9")
        XCTAssertTrue(api.createdSpecifications.isEmpty)
        XCTAssertEqual(transfers.uploads.count, 1)
    }

    /// #3: a re-attached download answered with a 503 is retried like a
    /// fresh one; the paid job is neither failed nor deleted.
    func testReattachedDownloadAnswered503IsRetried() async throws {
        let file = CCExportedFile(filename: "book.mobi", size: 9, url: URL(string: "https://storage.example/book.mobi")!)
        _ = try await seedPreviousLaunch(phase: .downloading, configuration: configuration, api: api) {
            $0.exportedFiles = [ExportedFileRecord(file)]
            $0.downloadTransfers = [0: "download-from-last-launch"]
        }
        transfers.reattach = { _ in outcome(503) }

        let handles = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.files.map(\.filename), ["book.mobi"])
        XCTAssertEqual(transfers.reattached, ["download-from-last-launch"])
        XCTAssertEqual(transfers.downloads.count, 1)
        await waitUntil { self.api.deletedJobIDsSnapshot == ["job-9"] }
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-9"], "deleted once the output is saved, not before")
    }

    /// #13: a re-attached upload that succeeded while the app was away is
    /// not sent again.
    func testReattachedUploadThatSucceededIsNotSentAgain() async throws {
        try await seedInterruptedUpload()
        transfers.reattach = { _ in outcome(201) }
        api.jobStatusScript = [.waiting, .processing, .finished]

        let handles = await engine.resumePendingConversions()
        let result = try await XCTUnwrap(handles.first).result

        XCTAssertEqual(result.jobID, "job-9")
        XCTAssertTrue(transfers.uploads.isEmpty)
    }

    /// #13: cancelling while waiting on a re-attached transfer cancels the
    /// conversion and cleans up.
    func testCancellingWhileWaitingOnAReattachedTransfer() async throws {
        try await seedInterruptedUpload()
        let gate = Gate()
        transfers.reattach = { _ in try await gate.wait(); return outcome(201) }

        let handles = await engine.resumePendingConversions()
        let handle = try XCTUnwrap(handles.first)
        await waitUntil { !self.transfers.reattached.isEmpty }
        handle.cancel()

        do {
            _ = try await handle.result
            XCTFail("expected cancellation")
        } catch let error as CloudConvertError {
            guard case .cancelled = error else { return XCTFail("unexpected \(error)") }
        }
        await waitUntil { !self.api.deletedJobIDsSnapshot.isEmpty }
        XCTAssertEqual(api.deletedJobIDsSnapshot, ["job-9"])
        let pending = await engine.pendingConversions()
        XCTAssertTrue(pending.isEmpty)
    }
}

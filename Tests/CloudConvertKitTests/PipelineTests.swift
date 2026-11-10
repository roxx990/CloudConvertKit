//  A conversion end to end: what it saves, what it leaves behind, and what
//  it keeps out of logs.
//

import XCTest
@testable import CloudConvertKit

final class PipelineTests: EngineTestCase {

    // MARK: Outputs

    func testSuccessfulConversionProducesFileWithOriginalName() async throws {
        let request = try request()
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

    func testMultipleExportedFilesAreAllDownloaded() async throws {
        api.exportFiles = [(filename: "page-1.jpg", size: 9, url: "https://storage.example/1"),
                           (filename: "page-2.jpg", size: 9, url: "https://storage.example/2")]
        let url = try TestFiles.makeFile(named: "scan.pdf")
        let result = try await engine.convert(ConversionRequest.convert(url, to: "jpg"))
        XCTAssertEqual(result.files.map(\.filename).sorted(), ["page-1.jpg", "page-2.jpg"])
        XCTAssertEqual(transfers.downloads.count, 2)
    }

    func testOutputsAreReadableByEveryone() async throws {
        let result = try await makeEngine().convert(try request())
        let permissions = try FileManager.default.attributesOfItem(atPath: result.files[0].url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o644)
    }

    /// Two inputs with the same file name are both uploaded intact.
    func testSameNamedInputsDoNotOverwriteEachOther() async throws {
        let a = try TestFiles.makeFile(named: "report.docx", bytes: 100)
        let b = try TestFiles.makeFile(named: "report.docx", bytes: 200)
        XCTAssertNotEqual(a, b)
        _ = try await engine.convert(ConversionRequest.merge([a, b], outputFilename: "both.pdf"))
        let sizes = transfers.uploads.map(\.bodySize).sorted()
        XCTAssertEqual(sizes.count, 2)
        XCTAssertEqual(sizes[1] - sizes[0], 100, "each upload carries its own file")
    }

    func testAnOutputTheServerSaysIsEmptyIsAccepted() async throws {
        api.exportFiles = [(filename: "notes.txt", size: 0, url: "https://storage.example/notes.txt")]
        transfers.downloadContent = Data()

        let result = try await engine.convert(try request("notes.docx", to: "txt"))

        XCTAssertEqual(result.files.map(\.size), [0])
        XCTAssertEqual(transfers.downloads.count, 1, "not retried")
    }

    // MARK: Failing before the upload or after the server

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
            _ = try await engine.convert(try request())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .exportMissing = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testAnEmptyDownloadOfAnOutputThatIsNotEmptyStillFails() async throws {
        transfers.downloadContent = Data()            // the server said 10 bytes
        do {
            _ = try await engine.convert(try request())
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .downloadFailed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testAbsurdOutputSizesDoNotTrap() async throws {
        api.exportFiles = [(filename: "a.pdf", size: .max, url: "https://storage.example/a"),
                           (filename: "b.pdf", size: .max, url: "https://storage.example/b")]
        do {
            _ = try await engine.convert(try request("scan.pdf", to: "pdf"))
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .insufficientDiskSpace = error else { return XCTFail("unexpected \(error)") }
        }
    }

    /// A multi-file conversion that fails after saving some outputs removes
    /// them: nobody was told about them.
    func testFailedMultiFileConversionRemovesTheOutputsItSaved() async throws {
        api.exportFiles = [(filename: "page-1.jpg", size: 9, url: "https://storage.example/1"),
                           (filename: "page-2.jpg", size: 9, url: "https://storage.example/2")]
        transfers.downloadStatuses = [200, 500]      // the second page never downloads

        do {
            _ = try await engine.convert(try request("scan.pdf", to: "jpg"))
            XCTFail("expected failure")
        } catch let error as CloudConvertError {
            guard case .downloadFailed = error else { return XCTFail("unexpected \(error)") }
        }
        let outputs = (try? FileManager.default.contentsOfDirectory(atPath: configuration.outputDirectory.path)) ?? []
        XCTAssertTrue(outputs.isEmpty, "left behind: \(outputs)")
    }

    // MARK: Privacy

    func testFileNamesAndServerTextStayOutOfLogMessages() async throws {
        let recorder = LogRecorder()
        configuration.logger = recorder
        engine = makeEngine(connectivity: AlwaysOnline())
        api.exportFiles = [(filename: "Payslip March.pdf", size: 10, url: "https://storage.example/out.pdf")]
        _ = try await engine.convert(try request("Payslip March.docx", to: "pdf"))
        api.jobStatusScript = [.error]
        api.failureCode = "ENGINE_EXPLODED"           // the task's message is "scripted failure"
        _ = try? await engine.convert(try request("Payslip April.docx", to: "pdf"))

        XCTAssertFalse(recorder.messages.contains { $0.contains("Payslip") }, "file names belong in (private) metadata")
        XCTAssertFalse(recorder.messages.contains { $0.contains("scripted failure") }, "so does the server's text")
        XCTAssertTrue(recorder.metadataValues.contains { $0.contains("Payslip") })
        XCTAssertTrue(recorder.metadataValues.contains("scripted failure"))

        let failure = CloudConvertError.jobFailed(jobID: "j", taskName: "convert", code: .other("ENGINE_EXPLODED"),
                                                  message: "Payslip March.pdf is encrypted")
        XCTAssertFalse(failure.userFacingMessage.contains("Payslip"))
    }
}

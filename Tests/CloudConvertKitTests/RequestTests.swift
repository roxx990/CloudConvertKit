//  Turning requests into jobs, and jobs into upload bodies.
//

import XCTest
@testable import CloudConvertKit

// MARK: - Job builder

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

// MARK: - Follow-up steps

final class FollowUpStepTests: XCTestCase {

    func testAConvertThenOptimizeJobChainsTheTasks() throws {
        let url = URL(fileURLWithPath: "/tmp/report.docx")
        var request = ConversionRequest.convert(url, to: "pdf")
        request.followUps = [ProcessingStep(.optimize(profile: "max"))]
        request.outputFilename = "small.pdf"

        let spec = try request.makeJobSpecification(defaultTag: nil, defaultTimeout: nil)
        let convert = try XCTUnwrap(spec.task(named: "process-1"))
        let optimize = try XCTUnwrap(spec.task(named: "step2-1"))
        XCTAssertEqual(optimize.operation, "optimize")
        XCTAssertEqual(optimize.inputs, ["process-1"])
        XCTAssertEqual(optimize.options["input_format"], .string("pdf"))
        XCTAssertEqual(optimize.options["profile"], .string("max"))
        XCTAssertEqual(optimize.options["filename"], .string("small.pdf"))
        XCTAssertNil(convert.options["filename"])
        XCTAssertEqual(spec.task(named: spec.exportTaskName)?.inputs, ["step2-1"])
    }

    func testEachFileConvertedThenArchivedIntoOne() throws {
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]
        var request = ConversionRequest.convert(urls, to: "jpg")
        request.followUps = [ProcessingStep(.archive())]

        let spec = try request.makeJobSpecification(defaultTag: nil, defaultTimeout: nil)
        XCTAssertEqual(spec.task(named: "step2-1")?.inputs, ["process-1", "process-2"])
        XCTAssertEqual(spec.task(named: spec.exportTaskName)?.inputs, ["step2-1"])
        // One archive comes out, so it may be named.
        request.outputFilename = "photos.zip"
        XCTAssertNoThrow(try request.makeJobSpecification(defaultTag: nil, defaultTimeout: nil))
    }

    func testAnOutputFilenameNeedsOneOutput() {
        var request = ConversionRequest.convert([URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")], to: "pdf")
        request.followUps = [ProcessingStep(.optimize())]
        request.outputFilename = "small.pdf"
        XCTAssertThrowsError(try request.makeJobSpecification(defaultTag: nil, defaultTimeout: nil),
                             "two files in, two files out: one name can't fit")
    }

    func testTheOutputFormatHintFollowsTheLastStep() throws {
        var request = ConversionRequest.convert(URL(fileURLWithPath: "/tmp/a.heic"), to: "png")
        request.followUps = [ProcessingStep(.convert(outputFormat: "webp")), ProcessingStep(.optimize())]
        let spec = try request.makeJobSpecification(defaultTag: nil, defaultTimeout: nil)
        let record = ConversionRecord(id: "c", specification: spec, staged: [:], output: .default, userInfo: [:],
                                      createdAt: Date(), updatedAt: Date(), phase: .preparing, jobAttempt: 1, jobID: nil,
                                      uploadTransfers: [:], uploadedTaskNames: [], downloadTransfers: [:], exportedFiles: [])
        XCTAssertEqual(record.outputFormatHint, "webp")
    }
}

// MARK: - Multipart bodies

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

    /// The file is copied a chunk at a time and each chunk freed as it goes.
    /// Only iOS's Foundation leaves the chunks for the pool, so this passes on
    /// macOS either way.
    func testTheFileIsNotHeldInMemory() throws {
        // Random bytes: a repeated byte held in memory compresses to almost nothing.
        let block = Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255) })
        let file = TestFiles.temporaryDirectory().appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        for _ in 0..<200 { try handle.write(contentsOf: block) }
        try handle.close()
        let form = CCUploadForm(url: URL(string: "https://upload.example/")!, parameters: [])
        let destination = TestFiles.temporaryDirectory().appendingPathComponent("large.multipart")

        let before = footprint()
        let body = try MultipartFormWriter.writeUploadBody(form: form, file: file, filename: "large.bin", to: destination)
        let held = footprint() - before
        XCTAssertGreaterThan(body.contentLength, 200 << 20)
        XCTAssertLessThan(held, 64 << 20, "a 200 MB upload body held \(held >> 20) MB")
    }

    private func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}

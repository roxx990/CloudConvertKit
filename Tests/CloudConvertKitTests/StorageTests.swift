//  Where outputs go: their names, collisions, and the room they need.
//

import XCTest
@testable import CloudConvertKit

final class StorageTests: XCTestCase {

    func testFilenameSanitisation() {
        XCTAssertEqual(FileStorage.sanitizedFilename("a/b\\c:d\"e.pdf"), "a-b-c-d'e.pdf")
        XCTAssertEqual(FileStorage.sanitizedFilename(".hidden"), "_hidden")
        XCTAssertEqual(FileStorage.sanitizedFilename("   "), "file")
        XCTAssertEqual(FileStorage.outputName(for: "My Report.docx", outputFormat: "PDF"), "My Report.pdf")
    }

    /// Many conversions saving `book.pdf` at the same moment each get their own file.
    func testConcurrentFinalizeNeverOverwrites() async throws {
        let work = TestFiles.temporaryDirectory(), out = TestFiles.temporaryDirectory()
        defer { [work, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        let storage = FileStorage(workingDirectory: work, outputDirectory: out, diskSpaceSafetyMargin: 0)
        let sources = try (0..<64).map { index -> URL in
            let url = work.appendingPathComponent("download-\(index)")
            try Data("file \(index)".utf8).write(to: url)
            return url
        }
        let finals = try await withThrowingTaskGroup(of: URL.self) { group -> [URL] in
            for source in sources {
                group.addTask { try storage.finalize(downloadedFile: source, preferredName: "book.pdf") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(finals.map(\.lastPathComponent)).count, 64)
        let contents = Set(try finals.map { try String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(contents.count, 64, "every file kept its own contents")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).count, 64)
    }

    func testFreeSpaceCountsTheUploadBodyAndTheOutputs() {
        // A 64 MB video compressed to 1 MB still needs room for its 64 MB upload body.
        XCTAssertEqual(ConversionEngine.requiredFreeSpace(inputSizes: [64 << 20], expectedOutputBytes: 1 << 20), 64 << 20)
        XCTAssertEqual(ConversionEngine.requiredFreeSpace(inputSizes: [10], expectedOutputBytes: 100), 100)
        XCTAssertEqual(ConversionEngine.requiredFreeSpace(inputSizes: [10, 20], expectedOutputBytes: nil), 60, "unchanged without an estimate")
    }
}

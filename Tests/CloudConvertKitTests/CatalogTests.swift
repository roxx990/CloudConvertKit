//  The formats catalogue: pairs, known failures, option checks, caching.
//

import XCTest
@testable import CloudConvertKit

// MARK: - Catalogue

final class CatalogTests: XCTestCase {

    static let rows: [CCOperation] = [
        CCOperation(operation: "convert", inputFormat: "docx", outputFormat: "pdf", engine: "office",
                    options: [option("pdf_a", values: [.bool(true), .bool(false)])]),
        CCOperation(operation: "convert", inputFormat: "doc", outputFormat: "pdf", engine: "office"),
        CCOperation(operation: "convert", inputFormat: "pdf", outputFormat: "docx", engine: "pdf2docx",
                    options: [option("pages")]),
    ]

    static func option(_ name: String, values: [JSONValue]? = nil) -> CCOperationOption {
        var object: [String: JSONValue] = ["name": .string(name)]
        if let values { object["possible_values"] = .array(values) }
        let data = try! JSONEncoder().encode(JSONValue.object(object))
        return try! JSONDecoder().decode(CCOperationOption.self, from: data)
    }

    private func catalog(_ api: FakeAPI, cache: URL? = nil, minimum: Int = 0) -> CloudConvertCatalog {
        CloudConvertCatalog(api: api, cacheURL: cache, minimumInputFormats: minimum)
    }

    func testPairsAndKnownFailures() async throws {
        let api = FakeAPI()
        api.conversions = Self.rows
        let catalog = catalog(api)
        let docxToPDF = try await catalog.supports(ConversionPair("docx", "pdf"))
        let docToPDF = try await catalog.supports(ConversionPair("doc", "pdf"))
        let docxToPNG = try await catalog.supports(ConversionPair("docx", "png"))
        let fromDOC = try await catalog.outputFormats(from: "doc")
        XCTAssertTrue(docxToPDF)
        XCTAssertFalse(docToPDF, "offered, but fails with EXPORT_FAILED")
        XCTAssertFalse(docxToPNG)
        XCTAssertEqual(fromDOC, [])
    }

    func testIssuesInARequest() async throws {
        let api = FakeAPI()
        api.conversions = Self.rows
        api.operationRows = ["merge": [CCOperation(operation: "merge", inputFormat: nil, outputFormat: "pdf", engine: "qpdf",
                                                   options: [Self.option("pdf_a")])]]
        let catalog = catalog(api)

        var request = ConversionRequest.convert(URL(fileURLWithPath: "/tmp/a.docx"), to: "pdf")
        request.options = ["pdf_a": .string("yes"), "quality": .int(90)]
        let convertIssues = try await catalog.issues(in: request)
        XCTAssertEqual(convertIssues, [
            .invalidValue(name: "pdf_a", value: .string("yes"), operation: "convert"),
            .unknownOption(name: "quality", operation: "convert"),
        ])

        let doc = ConversionRequest.convert(URL(fileURLWithPath: "/tmp/a.doc"), to: "pdf")
        let docIssues = try await catalog.issues(in: doc)
        XCTAssertEqual(docIssues, [.knownFailure(ConversionPair("doc", "pdf"))])

        // A pair listed without options (doc → pdf here, with no known failures) can't be judged.
        var unlisted = ConversionRequest.convert(URL(fileURLWithPath: "/tmp/a.doc"), to: "pdf")
        unlisted.options = ["anything": .int(1)]
        let unlistedIssues = try await CloudConvertCatalog(api: api, knownFailures: [], minimumInputFormats: 0).issues(in: unlisted)
        XCTAssertEqual(unlistedIssues, [])

        var merge = ConversionRequest.merge([URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")])
        merge.options = ["pages": .string("1")]
        let mergeIssues = try await catalog.issues(in: merge)
        XCTAssertEqual(mergeIssues, [.unknownOption(name: "pages", operation: "merge")])
    }

    func testTheListIsCachedOnDiskAndUsedWhenTheAPIFails() async throws {
        let cache = TestFiles.temporaryDirectory().appendingPathComponent("catalog.json")
        let api = FakeAPI()
        api.conversions = Self.rows
        _ = try await catalog(api, cache: cache).allConversions()

        let offline = FakeAPI()
        offline.convertFormatsError = .notConnected
        let rows = try await catalog(offline, cache: cache).allConversions()
        XCTAssertEqual(rows.count, Self.rows.count)
        XCTAssertEqual(rows.first?.options?.first?.name, "pdf_a")
        XCTAssertEqual(offline.convertFormatsCalls, 0, "a fresh cache needs no request")
    }

    func testAnExpiredCopyIsUsedWhenTheAPIFails() async throws {
        let cache = TestFiles.temporaryDirectory().appendingPathComponent("catalog.json")
        let api = FakeAPI()
        api.conversions = Self.rows
        _ = try await catalog(api, cache: cache).allConversions()

        let offline = FakeAPI()
        offline.convertFormatsError = .notConnected
        let stale = CloudConvertCatalog(api: offline, cacheURL: cache, maxAge: 0, minimumInputFormats: 0)
        let rows = try await stale.allConversions()
        XCTAssertEqual(rows.count, Self.rows.count, "a stale list beats none")
        XCTAssertEqual(offline.convertFormatsCalls, 1, "an expired copy is fetched again first")
    }

    func testEnginesAndOperationOptions() async throws {
        let api = FakeAPI()
        api.conversions = Self.rows
        api.operationRows = ["optimize": [CCOperation(operation: "optimize", inputFormat: "pdf", outputFormat: nil, engine: "3heights",
                                                      options: [Self.option("profile", values: [.string("web"), .string("max")])])]]
        let catalog = catalog(api)
        let engines = try await catalog.engines(for: ConversionPair("pdf", "docx"))
        XCTAssertEqual(engines, ["pdf2docx"])
        let names = try await catalog.options(forOperation: "optimize", inputFormat: "pdf").map(\.name)
        XCTAssertEqual(names, ["profile"])

        var request = ConversionRequest.convert(URL(fileURLWithPath: "/tmp/a.docx"), to: "pdf")
        request.followUps = [ProcessingStep(.optimize(), options: ["profile": .string("tiny")])]
        let issues = try await catalog.issues(in: request)
        XCTAssertEqual(issues, [.invalidValue(name: "profile", value: .string("tiny"), operation: "optimize")])
    }

    func testAListThatLooksCutShortIsNotCached() async throws {
        let cache = TestFiles.temporaryDirectory().appendingPathComponent("catalog.json")
        let api = FakeAPI()
        api.conversions = Self.rows
        _ = try await catalog(api, cache: cache, minimum: 50).allConversions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
}

//  The SwiftUI adapter's handling of interrupted conversions.
//

import XCTest
@testable import CloudConvertKit
import CloudConvertKitUI

@MainActor
final class ConversionViewModelTests: XCTestCase {

    /// Retrying an item whose conversion was interrupted resumes it: its job
    /// may still finish, and running the request again would bill it twice.
    func testRetryingAnInterruptedItemResumesIt() async throws {
        let api = FakeAPI(), transfers = FakeTransfers(), network = DroppedNetwork()
        api.serverHasUpload = { transfers.receivedUploadsSnapshot > 0 }
        api.getJobErrors = [.notConnected]          // the first poll finds the device offline
        let work = TestFiles.temporaryDirectory(), out = TestFiles.temporaryDirectory()
        defer { [work, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        let engine = ConversionEngine(configuration: .testing(workingDirectory: work, outputDirectory: out),
                                      api: api, transfers: transfers, connectivity: network)
        let model = ConversionViewModel(engine: engine)

        model.convert(ConversionRequest.convert(try TestFiles.makeFile(named: "book.epub"), to: "mobi"))
        for _ in 0..<300 where model.items.first?.error?.isResumable != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let id = try XCTUnwrap(model.items.first?.id)
        XCTAssertEqual(model.items.first?.state, .failed)

        network.isBack = true
        model.retry(id: id)
        for _ in 0..<300 where model.items.first?.state != .succeeded {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.items.map(\.id), [id], "the same conversion, resumed")
        XCTAssertEqual(model.items.first?.state, .succeeded)
        XCTAssertEqual(api.createdSpecifications.count, 1, "not converted a second time")
        XCTAssertEqual(transfers.uploads.count, 1)
    }
}

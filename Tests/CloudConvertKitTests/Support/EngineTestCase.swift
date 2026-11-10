//  The base of the engine's tests: the scripted API and transfers from
//  CloudConvertKitTesting, in directories of the test's own.
//

import XCTest
@testable import CloudConvertKit

/// `engine` is made on first use from `configuration`, so a test changes the
/// configuration first; `makeEngine` makes another, with other connectivity,
/// transfers or a record store.
class EngineTestCase: XCTestCase {

    var api: FakeCloudConvertAPI!
    var transfers: FakeFileTransfers!
    var configuration: CloudConvertConfiguration!
    private var directories: [URL] = []
    private var madeEngine: ConversionEngine?

    var engine: ConversionEngine {
        get {
            if let madeEngine { return madeEngine }
            let made = makeEngine()
            madeEngine = made
            return made
        }
        set { madeEngine = newValue }
    }

    override func setUp() {
        super.setUp()
        api = FakeCloudConvertAPI()
        transfers = FakeFileTransfers()
        let work = TestFiles.temporaryDirectory(), out = TestFiles.temporaryDirectory()
        directories = [work, out]
        configuration = .testing(workingDirectory: work, outputDirectory: out)
        let transfers = self.transfers!
        api.serverHasUpload = { transfers.receivedUploadsSnapshot > 0 }
    }

    override func tearDown() {
        madeEngine = nil
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    func makeEngine(connectivity: any ConnectivityMonitoring = AlwaysOnline(),
                    transfers: (any FileTransferring)? = nil,
                    store: (any ConversionRecordStoring)? = nil) -> ConversionEngine {
        ConversionEngine(configuration: configuration, api: api, transfers: transfers ?? self.transfers,
                         connectivity: connectivity, store: store)
    }

    /// A conversion of a new file, `report.docx` to PDF unless named otherwise.
    func request(_ name: String = "report.docx", to format: String = "pdf", bytes: Int = 1024,
                 key: String? = nil) throws -> ConversionRequest {
        var request = ConversionRequest.convert(try TestFiles.makeFile(named: name, bytes: bytes), to: format)
        request.key = key
        return request
    }
}

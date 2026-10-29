//  Built in the Swift 6 language mode, as an app is: the kit takes what such
//  an app holds (UIKit's completion handler, a main-actor view model, its
//  own observer) without boxes of its own.
//

import XCTest
import CloudConvertKit
import CloudConvertKitUI
import CloudConvertKitTesting

/// What an app reports account trouble with.
private struct AnalyticsObserver: AccountObserving {
    func conversionStopped(byAccountProblem error: CloudConvertError) {}
    func creditsRunningLow(remaining: Int) {}
}

@MainActor
final class AppShapedUsageTests: XCTestCase {

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudConvertKitSwift6-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEngine() -> ConversionEngine {
        var configuration = CloudConvertConfiguration.fetchingKey(backgroundSessionIdentifier: "swift6.\(UUID().uuidString)") {
            "key"
        }
        configuration.workingDirectory = temporaryDirectory()
        configuration.outputDirectory = temporaryDirectory()
        configuration.accountObserver = AnalyticsObserver()
        configuration.usesBackgroundTransfers = false
        configuration.polling = PollingPolicy(initialInterval: 0.01, maxInterval: 0.02, jobTimeout: 5)
        return ConversionEngine(configuration: configuration, api: FakeCloudConvertAPI(),
                                transfers: FakeFileTransfers(), connectivity: AlwaysOnline())
    }

    func testTheSystemsCompletionHandlerIsAcceptedAsIs() {
        // `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
        // hands over a plain, non-Sendable closure.
        let completionHandler: () -> Void = {}
        BackgroundTransferManager.handleEventsForBackgroundURLSession(identifier: "swift6.\(UUID().uuidString)",
                                                                      completionHandler: completionHandler)
    }

    func testAMainActorAppConvertsAndObservesProgress() async throws {
        let engine = makeEngine()
        let file = temporaryDirectory().appendingPathComponent("notes.docx")
        try Data(repeating: 1, count: 64).write(to: file)
        var request = ConversionRequest.convert(file, to: "pdf")
        request.key = "row-1"

        var stages: [ConversionProgress.Stage] = []
        let handle = engine.start(request)
        for await progress in handle.progress { stages.append(progress.stage) }
        let result = try await handle.result
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(stages.last, .completed)
    }

    func testTheViewModelAndLocalizationHook() {
        CloudConvertLocalization.setProvider { _, english in english }
        defer { CloudConvertLocalization.setProvider(nil) }
        let model = ConversionViewModel(engine: makeEngine())
        XCTAssertFalse(model.isRunning)
    }
}

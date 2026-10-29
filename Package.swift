// swift-tools-version: 6.0
import PackageDescription

// The kit is checked for data races (Swift 6's strict concurrency) while it
// builds in the Swift 5 language mode; Swift6Tests builds as an app on
// Swift 6 does, so the API takes what such an app holds.
let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
]

let package = Package(
    name: "CloudConvertKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        // Core: the whole CloudConvert pipeline. Depends only on Foundation, Network and os.
        .library(name: "CloudConvertKit", targets: ["CloudConvertKit"]),
        // Optional: an ObservableObject adapter for SwiftUI processing screens.
        .library(name: "CloudConvertKitUI", targets: ["CloudConvertKitUI"]),
        // For tests: a scripted API, transfers and connectivity, no network.
        .library(name: "CloudConvertKitTesting", targets: ["CloudConvertKitTesting"]),
    ],
    targets: [
        .target(
            name: "CloudConvertKit",
            path: "Sources/CloudConvertKit",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "CloudConvertKitUI",
            dependencies: ["CloudConvertKit"],
            path: "Sources/CloudConvertKitUI",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "CloudConvertKitTesting",
            dependencies: ["CloudConvertKit"],
            path: "Sources/CloudConvertKitTesting",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "CloudConvertKitTests",
            dependencies: ["CloudConvertKit", "CloudConvertKitUI", "CloudConvertKitTesting"],
            path: "Tests/CloudConvertKitTests",
            // Real `GET /v2/jobs/{id}` responses (signed URLs redacted).
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CloudConvertKitSwift6Tests",
            dependencies: ["CloudConvertKit", "CloudConvertKitUI", "CloudConvertKitTesting"],
            path: "Tests/Swift6Tests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v5]
)

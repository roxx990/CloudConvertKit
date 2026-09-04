// swift-tools-version: 5.9
import PackageDescription

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
    ],
    targets: [
        .target(
            name: "CloudConvertKit",
            path: "Sources/CloudConvertKit"
        ),
        .target(
            name: "CloudConvertKitUI",
            dependencies: ["CloudConvertKit"],
            path: "Sources/CloudConvertKitUI"
        ),
        .testTarget(
            name: "CloudConvertKitTests",
            dependencies: ["CloudConvertKit"],
            path: "Tests/CloudConvertKitTests"
        ),
    ]
)

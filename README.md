# CloudConvertKit

A dependency-free Swift package for the [CloudConvert v2 API](https://cloudconvert.com/api/v2). It owns the entire lifecycle of a file conversion, from validating the input to saving the output, and handles the failure modes that break most integrations: lost connections, files too large for memory, rate limits, expired upload forms, multi-file outputs, cancellation, and the app being suspended or killed mid-transfer.

[![Tests](https://github.com/roxx990/CloudConvertKit/actions/workflows/tests.yml/badge.svg)](https://github.com/roxx990/CloudConvertKit/actions/workflows/tests.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6.0%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2015%2B%20%7C%20macOS%2012%2B-blue.svg)](https://developer.apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

```swift
let engine = ConversionEngine(configuration: .direct(
    apiKey: key, environment: .sandbox, backgroundSessionIdentifier: "com.example.app.cloudconvert"))

let result = try await engine.convert(.convert(fileURL, to: "pdf")) { progress in
    print(progress.stage, progress.fractionCompleted)
}
print(result.files[0].url)
```

That one call creates the job, uploads the file on a background session, polls until the server is done, downloads every exported file, saves them under unique names, and deletes the remote job. Retries, backoff, offline waiting and cleanup happen underneath. If the app is killed halfway through, one call at next launch picks the conversion back up.

- **No third-party dependencies.** Imports only Foundation, Network and os.
- **Never bills a file twice.** A conversion whose job exists is kept, not thrown away, when the network or the time runs out, and resumed later; a request with a `key` continues it instead of converting again.
- **No UI.** The core never imports UIKit, SwiftUI or Combine. It talks to the app through `async` calls, an `AsyncStream` of progress values and a single error type. The optional `CloudConvertKitUI` adds an `ObservableObject` for SwiftUI.
- **One error type.** `CloudConvertError` has user-safe text, whom it blames, whether to retry or resume, and a stable analytics code. Every message goes through one localization hook.
- **Concurrency-clean.** Builds without warnings under strict concurrency checking, and a test target built in the Swift 6 language mode uses it as an app does.
- **Tested.** 171 tests on macOS, the iOS simulator and under Thread Sanitizer, against in-memory fakes with no network, run by CI on every change. The fakes ship as `CloudConvertKitTesting`, for your own tests.

## Requirements

- iOS 15+ / macOS 12+; Mac Catalyst works unchanged
- A Swift 6 toolchain (Xcode 16 or newer). Your code may use the Swift 5 or 6 language mode.

## Installation

**Xcode:** **File ▸ Add Package Dependencies…**, paste `https://github.com/roxx990/CloudConvertKit.git`, choose **Up to Next Major Version** from `2.0.0`, and add `CloudConvertKit` (and `CloudConvertKitUI` for the SwiftUI adapter) to your app target.

**Package.swift:**

```swift
.package(url: "https://github.com/roxx990/CloudConvertKit.git", from: "2.0.0"),
// per target:
.product(name: "CloudConvertKit", package: "CloudConvertKit"),
.product(name: "CloudConvertKitUI", package: "CloudConvertKit"),   // optional
```

| Product | Imports | What it is |
|---|---|---|
| `CloudConvertKit` | Foundation, Network, os | The pipeline. Everything an app needs. |
| `CloudConvertKitUI` | CloudConvertKit, Combine | `ConversionViewModel`: an `@MainActor ObservableObject` for a processing screen. Optional. |
| `CloudConvertKitTesting` | CloudConvertKit | `FakeCloudConvertAPI`, `FakeFileTransfers`, `FakeConnectivity`, `AlwaysOnline`, `AlwaysOffline`: scripted fakes for tests. |

## Quick start

### Set up once

```swift
import CloudConvertKit

enum ConversionServices {
    static let engine = ConversionEngine(configuration: .fetchingKey(
        backgroundSessionIdentifier: "com.example.app.cloudconvert") {
        try await RemoteAPIKey.fetch()          // your key store; or `.proxy(…)` to keep the key on your server
    })
}
```

Create **one** engine per background session identifier and keep it for the life of the process. Which setup to ship (a key in the app, fetched at runtime, or your own backend): [Configuration](Docs/Configuration.md).

### Convert

```swift
var request = ConversionRequest.convert(fileURL, to: "pdf")
request.key = row.id.uuidString                 // "Try again" on this row never bills twice

let handle = ConversionServices.engine.start(request)
for await progress in handle.progress {
    print(progress.localizedStageDescription, progress.fractionCompleted)   // arbitrary threads
}
let result = try await handle.result            // result.files: every exported file, saved
```

### On iOS

Hand the app delegate's background session events to the kit, and resume what the last launch left:

```swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Task { _ = await ConversionServices.engine.resumePendingConversions() }
    return true
}

func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    BackgroundTransferManager.handleEventsForBackgroundURLSession(identifier: identifier,
                                                                  completionHandler: completionHandler)
    _ = ConversionServices.engine
}
```

The rest, and the Mac: [App lifecycle](Docs/App-Lifecycle.md).

## Documentation

| Page | Covers |
|---|---|
| [Configuration](Docs/Configuration.md) | The key in the app, fetched at runtime or behind your backend; the proxy contract; files on disk and the privacy manifest |
| [Converting](Docs/Converting.md) | Requests, options, keys, follow-up steps, task graphs, batching, the formats catalogue, progress |
| [SwiftUI](Docs/SwiftUI.md) | `ConversionViewModel`: a processing screen, retrying and cancelling |
| [App lifecycle](Docs/App-Lifecycle.md) | Background transfers and time on iOS, interrupted conversions and resuming them, macOS |
| [Errors](Docs/Errors.md) | `CloudConvertError`, categories, localization, the account observer, what logs hold |
| [Edge cases](Docs/Edge-Cases.md) | What a direct integration usually misses, and the behaviour in every situation |
| [Architecture](Docs/Architecture.md) | Source layout, the public API, design decisions |
| [Testing](Docs/Testing.md) | Running the suite on macOS and iOS, what each test file covers, the stress test, CI |
| [Migrating from 1.x](Docs/Migrating-from-1.x.md) | Moving an app to 2.x |

## Versioning

Releases follow [semantic versioning](https://semver.org) and are published as git tags (`2.0.0`, `2.1.0`, …); depend on **Up to Next Major Version**. A major release may change public API or default behaviour, a minor one adds API, a patch only fixes bugs. Every release is listed in [CHANGELOG.md](CHANGELOG.md).

## Contributing

Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE). This is an independent project and is not affiliated with or endorsed by CloudConvert.

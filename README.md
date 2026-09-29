# CloudConvertKit

A dependency-free Swift package for the [CloudConvert v2 API](https://cloudconvert.com/api/v2). It owns the entire lifecycle of a file conversion, from validating the input to saving the output, and handles the failure modes that break most integrations: lost connections, files too large for memory, rate limits, expired upload forms, multi-file outputs, cancellation, and the app being suspended or killed mid-transfer.

[![Swift 5.9](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
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
- **No UI.** The core never imports UIKit, SwiftUI or Combine. It talks to the app through `async` calls, an `AsyncStream` of progress values and a single error type. A separate optional product provides an `ObservableObject` adapter for SwiftUI.
- **Concurrency-clean.** Builds without warnings under `-strict-concurrency=complete`.
- **Tested.** 39 tests covering orchestration, resume, cancellation, retry arithmetic and decoding, running against in-memory fakes with no network.

## Requirements

iOS 15+, macOS 12+, Swift 5.9+ (Xcode 15 or newer). Mac Catalyst works unchanged.

## Installation

**Swift Package Manager**

```swift
.package(url: "https://github.com/roxx990/CloudConvertKit.git", from: "1.0.1"),
// then, per target:
.product(name: "CloudConvertKit", package: "CloudConvertKit")
```

**Xcode:** File ▸ Add Package Dependencies… ▸ paste the repository URL ▸ add the `CloudConvertKit` product to your app target, and `CloudConvertKitUI` as well if you want the SwiftUI adapter.

## Products

| Product | Imports | What it is |
|---|---|---|
| `CloudConvertKit` | Foundation, Network, os | The pipeline. Everything an app needs. |
| `CloudConvertKitUI` | CloudConvertKit, Combine | `ConversionViewModel`: an `@MainActor ObservableObject` for a processing screen. Optional. |

## What this handles that a direct integration usually does not

Most hand-rolled CloudConvert clients are a hundred lines that work on a fast connection with small files and fail everywhere else. Each row below is a failure this package exists to prevent:

| Common mistake | Consequence | What the package does instead |
|---|---|---|
| Reading the file with `Data(contentsOf:)` and building the multipart body in memory | Jetsam kill on large inputs; every big file "fails" | Streams the body to disk in 1 MiB chunks on a dedicated IO queue, then uploads with `uploadTask(fromFile:)` |
| Uploading on `URLSession.shared` | Transfer dies the moment the app is backgrounded | A background `URLSession` whose transfers continue while suspended and are re-attached after relaunch |
| No retries or backoff | One dropped packet, one 5xx or one 429 ends the conversion | Exponential backoff with jitter at the API, upload, download and job levels, honouring `Retry-After` |
| No reachability handling | Offline means instant failure with a confusing message | Requests are not attempted while offline; in-flight work waits for the network and reports `.waitingForNetwork` |
| Never checking the upload response status | A rejection from storage is treated as success, then polling never ends | Every transfer outcome is validated; a rejection rebuilds the job with a fresh form |
| Polling on a fixed interval with no deadline | A stuck job polls until the process dies | Growing interval, hard deadline, bounded failure budget |
| Downloading only `files.first` | Multi-file outputs such as PDF to JPG silently lose pages | Every exported file is downloaded, or one zip via `archive_multiple_files` |
| `NSError` with a string domain | No way to tell retryable from fatal, nothing safe to show the user | One error type carrying `isRetryable`, `isCancellation`, `userFacingMessage` and `analyticsCode` |
| Never deleting the job | Inputs and outputs sit on CloudConvert for 24 hours | The job is deleted as soon as the outputs are saved, and on failure or cancellation |
| No cancellation path | Orphaned temporary files and jobs still consuming credits | Structured cancellation cleans up locally and remotely |
| Using document-picker URLs directly | Intermittent "file not readable" once the picker's scope ends | Inputs are copied into the package's own directory through `NSFileCoordinator` |
| Shipping the API key in the app | Key extraction and quota abuse | Authentication is a protocol; the proxy environment keeps the key server-side |

## Architecture

```
Sources/
├── CloudConvertKit/
│   ├── Core/          Configuration, error taxonomy, JSON value, logging, file storage,
│   │                  blocking-IO helper, background-activity hook
│   ├── Models/        Codable mirrors of jobs / tasks / upload forms / exports / operations / user / pages
│   ├── JobBuilding/   TaskDefinition, JobSpecification, JobBuilder (fluent), ConversionRequest (high level)
│   ├── Networking/    Auth provider, retry policy, connectivity, HTTP transport, multipart writer,
│   │                  background transfer manager
│   ├── API/           Typed endpoints (jobs, tasks, operations, formats, user)
│   └── Engine/        ConversionEngine (orchestrator), JobPoller, ProgressReporter,
│                      ConversionRecordStore (crash-safe state), ConversionQueue (concurrency limit)
└── CloudConvertKitUI/ ConversionViewModel (ObservableObject) — optional
```

Dependency direction is strictly downwards: UI → Engine → API/Networking → Models/Core. Every seam is a protocol (`CloudConvertAPIClient`, `FileTransferring`, `ConnectivityMonitoring`, `ConversionRecordStoring`, `AuthorizationProvider`, `HTTPTransport`, `CloudConvertLogging`, `BackgroundActivityProviding`), so any layer can be replaced or faked.

## Configuration

Build one configuration at launch and keep one engine per background session identifier for the life of the process.

### Talking to CloudConvert directly

Fine for development, sandbox work and Mac tools. The key is in the app, so treat it as public.

```swift
CloudConvertConfiguration.direct(apiKey: key,
                                 environment: .sandbox,
                                 backgroundSessionIdentifier: "com.example.app.cloudconvert")
```

Available environments: `.production`, `.europe`, `.unitedStates`, `.sandbox`, and `.proxy(baseURL:)`.

> **Always pass `environment:` explicitly.** If you leave it out, `direct(...)` uses **`.sandbox`**, not `.production`. A production API key sent to the sandbox fails with `401` (`CloudConvertError.unauthorized`). The default will be removed in the next major version.

### Through your own backend (recommended for shipping apps)

The app never holds the CloudConvert key. See [Proxy contract](#proxy-contract) for what the server must do.

```swift
enum ConversionServices {
    static let configuration: CloudConvertConfiguration = {
        var configuration = CloudConvertConfiguration.proxy(
            baseURL: URL(string: "https://api.example.com/cloudconvert/v2")!,
            authorization: RefreshableTokenAuthorization { try await AppAuth.currentToken() },
            backgroundSessionIdentifier: "com.example.app.cloudconvert",
            jobTag: "ios-\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "")")
        configuration.maxConcurrentConversions = 2
        configuration.serverTaskTimeout = 25 * 60        // seconds, sent as `timeout` on tasks
        configuration.polling.jobTimeout = 40 * 60       // give up polling after this
        return configuration
    }()

    static let engine = ConversionEngine(configuration: configuration)
}
```

### Fetching the key at runtime

If the key lives in a remote config store (Firebase Realtime Database, Remote Config, your own endpoint), supply a closure. `RefreshableTokenAuthorization` fetches on first use, caches, sends `Authorization: Bearer <key>`, and on a 401 drops the cache and fetches once more, so rotating the key takes effect without an app update. The package has no dependency on any of those SDKs.

```swift
CloudConvertConfiguration(
    environment: .production,
    authorizationProvider: RefreshableTokenAuthorization { try await RemoteAPIKey.fetch() },
    backgroundSessionIdentifier: "com.example.app.cloudconvert")
```

Persist the last good key in the Keychain inside your fetcher so an outage or a cold start without network does not block a conversion. Note this improves on hardcoding (instant rotation, nothing in the binary) but the key still reaches the device, so it is not a substitute for a proxy.

## Usage

### Converting

```swift
// DOCX → PDF
let result = try await engine.convert(.convert(fileURL, to: "pdf")) { progress in
    print(progress.stage, progress.fractionCompleted)          // called on arbitrary threads
}

// With engine options
ConversionRequest.convert(fileURL, to: "mp3", options: ["audio_bitrate": 192, "audio_channels": 2])
ConversionRequest.convert(fileURL, to: "mp4", options: ["video_codec": "x264", "height": 1080, "fit": "scale"])
ConversionRequest.convert(imageURL, to: "webp", options: ["quality": 80, "strip": true])

// PDF → JPG produces one file per page; every page is downloaded
ConversionRequest.convert(pdfURL, to: "jpg", options: ["quality": 85])

// Merge several files into one PDF
ConversionRequest.merge([a, b, c], outputFilename: "combined.pdf")

// Several files, each converted, in one job
ConversionRequest.convert([url1, url2], to: "epub")
```

Attach your own data with `request.userInfo`, and it comes back on the result.

### Observing instead of awaiting

```swift
let handle = engine.start(request)
Task { for await progress in handle.progress { await MainActor.run { model.progress = progress } } }
let result = try await handle.result
handle.cancel()
```

### Arbitrary task graphs

Anything `ConversionRequest` cannot express is built with `JobBuilder` and run through `engine.run(spec)` or `engine.start(spec)`:

```swift
var builder = JobBuilder(tag: "example")
let file = builder.importUpload(InputFile(url: url))
let pdf = builder.convert(file, to: "pdf", options: ["pages": "1-3"])
let small = builder.optimize(pdf, profile: "web")
builder.exportURL(small)
let result = try await engine.run(try builder.build())
```

Supported operations: `convert`, `merge`, `archive`, `optimize`, `thumbnail`, `watermark`, `metadata`, plus `import/upload`, `import/url`, `import/base64`, `import/raw`, `export/url`, and `addTask` for anything else.

### Batching

`ConversionQueue` bounds concurrency (default 2) so twenty files do not create twenty jobs at once and trip the rate limit.

```swift
let queue = ConversionQueue(engine: engine, maxConcurrent: 2)
let handles = await queue.enqueue(requests)
await queue.cancelAll()
```

### SwiftUI

```swift
import CloudConvertKitUI

struct ProcessingView: View {
    @StateObject private var model = ConversionViewModel(engine: ConversionServices.engine)

    var body: some View {
        List(model.items) { item in
            VStack(alignment: .leading) {
                Text(item.request.inputs.first?.effectiveFilename ?? "")
                ProgressView(value: item.fractionCompleted)
                Text(item.statusText).font(.caption)
                if item.state == .failed { Button("Retry") { model.retry(id: item.id) } }
            }
        }
        .toolbar { Button("Cancel all") { model.cancelAll() } }
        .onAppear { model.convert(requests) }
    }
}
```

Apps using `@Observable` or their own architecture can use `ConversionQueue` and `ConversionHandle` directly. The view model is about 150 lines of reference code, not a requirement.

### Discovering formats and options

Option names come from the engine behind each conversion and change over time, so the API is the source of truth:

```swift
let ops = try await engine.availableOperations(
    OperationsFilter(inputFormat: "heic", outputFormat: "jpg", includeOptions: true))

let credits = try await engine.apiClient.currentUser().credits    // needs the user.read scope
```

## App lifecycle

### iOS

Two small pieces of UIKit glue live in your app, not in the package. First, background transfers deliver their events through the app delegate:

```swift
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = ConversionServices.engine               // creates the background session early
        Task { _ = await ConversionServices.engine.resumePendingConversions() }
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        _ = ConversionServices.engine
        BackgroundTransferManager.shared(for: identifier)?.setBackgroundCompletionHandler(completionHandler)
    }
}
```

`resumePendingConversions()` returns handles for conversions that were in flight when the app last died, so a processing screen can show them finishing. Conversions running in the current process are never reported as pending or started twice.

Second, optionally, let the pipeline ask for extra execution time when the app is backgrounded between transfers. This keeps the package free of UIKit:

```swift
struct UIKitBackgroundActivity: BackgroundActivityProviding {
    func beginActivity(named name: String) -> BackgroundActivityToken? {
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(identifier)   // expiration: must end it
            identifier = .invalid
        }
        return identifier == .invalid ? nil : BackgroundActivityToken(rawValue: identifier.rawValue)
    }
    func endActivity(_ token: BackgroundActivityToken) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token.rawValue))
    }
}
```

Then set `configuration.backgroundActivity = UIKitBackgroundActivity()`.

### macOS

Everything builds and the whole test suite runs natively. There is no `handleEventsForBackgroundURLSession` to wire, so skip that step; `usesBackgroundTransfers = false` is fine. Sandboxed apps get security-scoped `NSOpenPanel` URLs, which staging already handles. If your app can be App-Napped mid-conversion, implement `BackgroundActivityProviding` with `ProcessInfo.processInfo.beginActivity(options:reason:)` instead of the UIKit version above.

## Public API surface

| Area | Types | Notes |
|---|---|---|
| Orchestration | `ConversionEngine` — `convert`, `run`, `start`, `pendingConversions`, `resumePendingConversions`, `discardPendingConversion`, `availableOperations`, `apiClient` | One instance per app |
| Handles | `ConversionHandle` — `id`, `progress: AsyncStream`, `result`, `cancel()`, `isCancelled` | Returned by `start` / queue / resume |
| Batching | `ConversionQueue` — `enqueue(request)`, `enqueue(spec)`, `cancel(id:)`, `cancelAll()` | Actor; bounds concurrency |
| Requests | `ConversionRequest`, `ProcessingOperation`, `InputFile`, `ExportOptions`, `OutputOptions` | The everyday entry point |
| Job graphs | `JobBuilder`, `JobSpecification`, `TaskDefinition`, `TaskRef`, `CCOperationName` | Any CloudConvert task graph |
| Progress / result | `ConversionProgress` (+ `Stage`, `RetryScope`), `ConversionResult`, `ConvertedFile` | Sendable value types |
| Errors | `CloudConvertError`, `TaskFailureCode`, `APIErrorPayload`, `ConversionPhase` | One taxonomy for everything |
| Configuration | `CloudConvertConfiguration`, `CloudConvertEnvironment`, `RetryPolicy`, `PollingPolicy`, `ProgressWeights` | All tunables in one struct |
| Endpoints | `CloudConvertAPIClient` — jobs (`create`, `get`, `list`, `delete`), tasks (`get`, `retry`, `cancel`, `delete`), `operations`, `convertFormats`, `currentUser` | `CloudConvertAPI` is the URLSession implementation |
| Models | `CCJob`, `CCTask`, `CCTaskResult`, `CCUploadForm`, `CCExportedFile`, `CCOperation`, `CCOperationOption`, `CCUser`, `CCPage`, `CCStatus`, `JSONValue` | Lenient decoding |
| Seams | `AuthorizationProvider`, `HTTPTransport`, `FileTransferring`, `ConnectivityMonitoring`, `ConversionRecordStoring`, `CloudConvertLogging`, `BackgroundActivityProviding` | Implement to replace or fake a layer |
| Persistence | `ConversionRecord`, `ConversionRecordStore`, `PersistedTransfer`, `TransferOutcome` | Crash-safe state |

Progress handlers and `AsyncStream`s deliver values on arbitrary threads; hop to the main actor in your app.

## Progress model

`ConversionProgress.fractionCompleted` folds the three network phases with `ProgressWeights` (upload 45 %, processing 35 %, download 20 % by default) and never moves backwards within a job attempt. `stage` tells the UI what is happening, including `.waitingForNetwork` and `.retrying(attempt:delay:scope:reason:)`, so a screen can say "Reconnecting…" instead of freezing. Every conversion ends with exactly one terminal stage: `.completed`, `.failed` or `.cancelled`.

## Error model

Every failure is a `CloudConvertError`:

- `userFacingMessage` — safe alert text, never contains URLs or server payloads
- `isRetryable` — whether offering a "Try again" button makes sense
- `isCancellation` — show nothing, or a neutral "Cancelled" state
- `isConnectivityRelated` — show an offline banner rather than an error alert
- `analyticsCode` — stable string for analytics dashboards (`http_429`, `job_failed_invalid_conversion_type`, `upload_rejected_403`, …)

## Edge-case matrix

| Situation | Behaviour |
|---|---|
| Device offline when a conversion starts | Not attempted; `stage == .waitingForNetwork` until the network returns or `offlineWaitTimeout` (90 s) elapses → `.notConnected`. The job is not rebuilt: it already waited the full timeout |
| Connection lost during upload or download | The background session waits for connectivity; if the task errors, the phase retries (upload 3×, download 4×) after waiting for the network. Offline waits do not consume retry attempts. The UI sees `.retrying(scope: .phase(…))` |
| Connection lost while polling | Polling pauses, resumes when back online, and does not count toward the failure budget |
| App backgrounded during a large upload | The upload continues in the background session |
| App backgrounded while polling | `BackgroundActivityProviding`, if wired, buys about 30 seconds; otherwise polling resumes when the app returns |
| App killed mid-upload | On relaunch, `resumePendingConversions()` re-attaches to the running transfer or picks up its persisted outcome; if the transfer is gone the upload restarts against the same job when the form is still valid, otherwise the job is rebuilt |
| App killed while the server is converting | On relaunch the job is re-fetched by id and polling continues; nothing is re-uploaded |
| App killed during download | The download is re-attached or restarted; already-saved files are not fetched again |
| `resumePendingConversions()` called twice, or while conversions run | Running conversions are never reported as pending or started twice |
| Records older than 20 h | Not resumed, since the server purges jobs at 24 h; cleaned up and reported as `.jobLost` |
| 429 rate limit | `Retry-After` honoured, falling back to backoff; the queue limits concurrent job creation |
| 5xx, malformed JSON, or HTML from a CDN | Retried with exponential backoff and jitter (5 attempts for API calls) |
| 401 | One transparent credential refresh via `AuthorizationProvider.handleUnauthorized()`, then fails without further retries |
| 402 (credits), 403, 422 | Not retried; specific error cases with safe user text |
| Upload form expired, or storage returned 4xx | The whole job is rebuilt with a fresh form, once by default |
| Storage returned 5xx on upload | The same request is retried against the same form |
| Task error `TIMEOUT`, `INPUT_TASK_FAILED`, or an unknown code | Job rebuilt once |
| Task error `INVALID_CONVERSION_TYPE`, `CONVERSION_FAILED`, `OPEN_FAILED`, `SANDBOX_FILE_NOT_ALLOWED`, `FILE_TOO_LARGE` | Not retried, since it would only burn credits; the user gets a specific message |
| Job disappears (404) | `.jobLost`, rebuilt once |
| Job stuck in `processing` past `polling.jobTimeout` | `.jobTimedOut`, not retried |
| Finished job with no exported files | `.exportMissing`, not retried |
| Multiple exported files | All downloaded, or one zip via `ExportOptions.archiveMultipleFiles` |
| Export URL expired (403/404/410 on download) | Treated as `.jobLost`, so the job is rebuilt once |
| Downloaded file is empty | Retried as a download failure |
| Input missing, unreadable, empty, or over the size limit | Fails locally before any network call |
| Input larger than the form's `max_file_size` | Fails before uploading |
| Not enough disk space for the output | Fails before uploading, and again before downloading with the real size |
| Output filename collision | `name (2).ext`, `name (3).ext`, … |
| Filenames with quotes, slashes or control characters | Sanitised for both the multipart header and the file system |
| Document-picker or Photos URLs | Security scope handled; the file is copied via `NSFileCoordinator` into the package's staging directory |
| Large files | The staging copy and the multipart body are written in 1 MiB chunks on a dedicated IO queue, never in memory and never on a Swift-concurrency thread |
| User cancels, in any phase including the delay before a rebuild | URLSession tasks cancelled, temporary files removed, server job deleted, record removed, exactly one `.cancelled` stage |
| Success | The server job is deleted immediately for privacy, temporary files removed, record removed |
| Crash leaving temporary files behind | Anything older than 48 h is purged at engine init |
| Unknown future job or task status string | Decoded as `processing` so polling continues instead of crashing |
| Odd catalogue rows (booleans as 0/1, numbers as strings) | Models decode leniently; one odd row never breaks the list |
| `percent` reported by the server | Used for the processing phase; otherwise a time-based estimate that never reaches 100 % early |
| Metered connections | `allowsCellularTransfers = false` restricts transfers to Wi-Fi |

## Proxy contract

`CloudConvertEnvironment.proxy(baseURL:)` points the JSON API calls at your server, which must:

1. Expose the same paths under its base URL: `POST /jobs`, `GET /jobs`, `GET /jobs/{id}`, `DELETE /jobs/{id}`, `GET /tasks/{id}`, `POST /tasks/{id}/retry`, `POST /tasks/{id}/cancel`, `DELETE /tasks/{id}`, and optionally `GET /operations`, `GET /convert/formats`, `GET /users/me`.
2. Forward the request body and query string unchanged to `https://api.cloudconvert.com/v2/…` (or a regional host) with `Authorization: Bearer <API key>` added server-side.
3. Return CloudConvert's status code and JSON body unchanged, **including** the `Retry-After`, `X-RateLimit-Limit` and `X-RateLimit-Remaining` headers, which the package reads.
4. Authenticate the app however you like. The package sends whatever `AuthorizationProvider` returns as the `Authorization` header plus `additionalHeaders()`; on a 401 it calls `handleUnauthorized()` once and retries with fresh credentials.

Uploads (`upload.cloudconvert.com`) and downloads (`storage.cloudconvert.com`) go directly to CloudConvert storage using the pre-signed form and URLs from the job response, so the proxy never carries file bytes.

Optionally the proxy can enforce per-user quotas, strip `webhook_url`, force a `tag`, or restrict operations. It must not alter task names or the `result.form` object.

## File locations

Everything lives under `Application Support/<bundle id>/CloudConvertKit/`: `Work/` for staging, multipart bodies, in-flight downloads and records, and `Converted/` for outputs. Application Support is app-private on both platforms, so nothing lands in a user-visible folder on macOS, and the bundle-identifier segment keeps unsandboxed Mac apps apart. Override `outputDirectory` per configuration or `OutputOptions.directory` per request. `Work/` is excluded from backups; `Converted/` is not.

During a conversion the package holds up to two extra copies of the input on disk (the staged copy and the multipart body); the pre-flight free-space check accounts for it.

## Design decisions

- **Polling rather than the sync API or sockets.** A long-lived HTTP request is the least reliable thing on a phone. Polling with a growing interval (1 s → 6 s) survives app switches and cellular handovers, and the request volume is negligible.
- **One job per file for conversions, one job per batch for merge and archive.** A single bad file cannot fail a whole batch.
- **Job-level retry rebuilds the whole job** rather than calling `POST /tasks/{id}/retry`. It costs a re-upload but does not depend on server-side retry semantics that are undocumented for chained tasks.
- **Inputs are staged.** Copying doubles temporary disk use for the duration of a conversion, but makes the pipeline immune to the source disappearing and lets background sessions read the file.
- **Validation and disk-space checks happen before any credit is spent.**
- **Records persist as JSON files** rather than a database; there are only ever a handful of them.
- **Platform glue is injected**, so the core stays platform-neutral and fully testable.

## Testing

```bash
swift test
```

The suite runs entirely against in-memory fakes for the API, the transfer layer and connectivity. It covers the happy path, output naming, multi-file export, deterministic versus transient failure handling, upload rejection leading to a job rebuild, storage 5xx retrying against the same form, offline timeouts, cancellation cleanup both mid-upload and during a rebuild delay, resuming from a persisted record without re-uploading, running conversions being excluded from "pending", queue concurrency, retry and backoff arithmetic, error mapping, and model decoding.

`Tests/CloudConvertKitTests/Fixtures/` holds real `GET /v2/jobs/{id}` responses (a finished job and a failed one, signed URLs redacted). The regression tests run them through the real `CloudConvertAPI` decoder, and the fakes follow the same shapes: only export tasks list files with a `url`, and an engine that cannot convert a file reports `code: null`.

`StressTests` runs 150 conversions at once against a simulated CloudConvert with seeded faults at every layer, including cancellation at random moments. It then checks that every conversion ends exactly once, that no file is billed twice, that every known job is deleted and that no local state is left. Each run prints its seed; replay one or scale up with:

```bash
CCK_STRESS_SEED=1790701569452 CCK_STRESS_COUNT=1000 swift test --filter StressTests
```

Run the suite under Thread Sanitizer with `swift test --sanitize=thread`. Codesign rejects test bundles built under `~/Documents` (Finder metadata), so build elsewhere there: `swift test --scratch-path /tmp/cck-build`.

For a live smoke test use `CloudConvertConfiguration.direct(apiKey:environment: .sandbox, …)` with a file whitelisted in the CloudConvert sandbox dashboard.

## Contributing

Issues and pull requests are welcome. Please keep the core free of third-party dependencies and of UI framework imports, and add a test alongside any behaviour change.

## License

MIT. See [LICENSE](LICENSE).

This is an independent project and is not affiliated with or endorsed by CloudConvert.

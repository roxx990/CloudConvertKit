# CloudConvertKit

A dependency-free Swift package for the [CloudConvert v2 API](https://cloudconvert.com/api/v2). It owns the entire lifecycle of a file conversion, from validating the input to saving the output, and handles the failure modes that break most integrations: lost connections, files too large for memory, rate limits, expired upload forms, multi-file outputs, cancellation, and the app being suspended or killed mid-transfer.

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
- **No UI.** The core never imports UIKit, SwiftUI or Combine. It talks to the app through `async` calls, an `AsyncStream` of progress values and a single error type. A separate optional product provides an `ObservableObject` adapter for SwiftUI.
- **Concurrency-clean.** Builds without warnings under strict concurrency checking, and a test target built in the Swift 6 language mode uses it as an app does.
- **Localizable.** Every message and stage description goes through one hook with stable keys.
- **Tested.** 175 tests covering orchestration, resume, cancellation, retry arithmetic and decoding, running against in-memory fakes with no network. The fakes ship as `CloudConvertKitTesting`, for your own tests.

## Requirements

iOS 15+, macOS 12+, a Swift 6 toolchain (Xcode 16 or newer). Your code may use the Swift 5 or 6 language mode. Mac Catalyst works unchanged.

## Installation

**Swift Package Manager**

```swift
.package(url: "https://github.com/roxx990/CloudConvertKit.git", from: "2.0.0"),
// then, per target:
.product(name: "CloudConvertKit", package: "CloudConvertKit")
```

**Xcode:** File ▸ Add Package Dependencies… ▸ paste the repository URL ▸ add the `CloudConvertKit` product to your app target, and `CloudConvertKitUI` as well if you want the SwiftUI adapter.

## Products

| Product | Imports | What it is |
|---|---|---|
| `CloudConvertKit` | Foundation, Network, os | The pipeline. Everything an app needs. |
| `CloudConvertKitUI` | CloudConvertKit, Combine | `ConversionViewModel`: an `@MainActor ObservableObject` for a processing screen. Optional. |
| `CloudConvertKitTesting` | CloudConvertKit | `FakeCloudConvertAPI`, `FakeFileTransfers`, `FakeConnectivity`, `AlwaysOnline`, `AlwaysOffline`: scripted fakes for tests. |

## What this handles that a direct integration usually does not

Most hand-rolled CloudConvert clients are a hundred lines that work on a fast connection with small files and fail everywhere else. Each row below is a failure this package exists to prevent:

| Common mistake | Consequence | What the package does instead |
|---|---|---|
| Reading the file with `Data(contentsOf:)` and building the multipart body in memory | Jetsam kill on large inputs; every big file "fails" | Streams the body to disk in 1 MiB chunks on a dedicated IO queue, then uploads with `uploadTask(fromFile:)` |
| Uploading on `URLSession.shared` | Transfer dies the moment the app is backgrounded | A background `URLSession` whose transfers continue while suspended and are re-attached after relaunch |
| No retries or backoff | One dropped packet, one 5xx or one 429 ends the conversion | Exponential backoff with jitter at the API, upload, download and job levels, honouring `Retry-After` |
| No reachability handling | Offline means instant failure with a confusing message | Requests are not attempted while offline; in-flight work waits for the network and reports `.waitingForNetwork`; a conversion whose job exists is kept, not lost, if the network stays away |
| Never checking the upload response status | A rejection from storage is treated as success, then polling never ends | Every transfer outcome is validated; a rejection rebuilds the job with a fresh form |
| Polling on a fixed interval with no deadline | A stuck job polls until the process dies | Growing interval, a deadline that ignores time spent suspended, one last check before giving up, bounded failure budget |
| Downloading only `files.first` | Multi-file outputs such as PDF to JPG silently lose pages | Every exported file is downloaded, or one zip via `archive_multiple_files` |
| `NSError` with a string domain | No way to tell retryable from fatal, nothing safe to show the user | One error type carrying `isRetryable`, `isCancellation`, `userFacingMessage` and `analyticsCode` |
| Never deleting the job | Inputs and outputs sit on CloudConvert for 24 hours | The job is deleted as soon as the outputs are saved, and on failure or cancellation; never while it may still finish |
| No cancellation path | Orphaned temporary files and jobs still consuming credits | Structured cancellation cleans up locally and remotely |
| Using document-picker URLs directly | Intermittent "file not readable" once the picker's scope ends | Inputs are copied into the package's own directory through `NSFileCoordinator` |
| Shipping the API key in the app | Key extraction and quota abuse | Authentication is a protocol; the proxy environment keeps the key server-side |
| Retrying "Convert" after a pause | The file is converted, and billed, twice | `ConversionRequest.key` continues the conversion kept for it instead |
| Sending an option the engine doesn't take | The job fails after the upload, credits spent | `validatesRequests` checks pair and options against the cached catalogue first |
| Blaming the file for an empty account | Users are told their file is broken | `CloudConvertError.category` tells input, account, connectivity and service apart; `AccountObserving` tells the developer |

## Architecture

```
Sources/
├── CloudConvertKit/
│   ├── Core/          Configuration, error taxonomy, localization hook, JSON value, logging,
│   │                  file storage, blocking-IO helper, background activity
│   ├── Models/        Codable mirrors of jobs / tasks / upload forms / exports / operations / user / pages
│   ├── JobBuilding/   TaskDefinition, JobSpecification, JobBuilder (fluent), ConversionRequest (high level)
│   ├── Networking/    Auth provider, retry policy, connectivity, HTTP transport, multipart writer,
│   │                  background transfer manager
│   ├── API/           Typed endpoints (jobs, tasks, operations, formats, user), CloudConvertCatalog
│   └── Engine/        ConversionEngine (orchestrator), JobPoller, ProgressReporter,
│                      ConversionRecordStore (crash-safe state), ConversionQueue (concurrency limit)
├── CloudConvertKitUI/ ConversionViewModel (ObservableObject) — optional
└── CloudConvertKitTesting/ Fakes for the API, transfers and connectivity
```

Dependency direction is strictly downwards: UI → Engine → API/Networking → Models/Core. Every seam is a protocol (`CloudConvertAPIClient`, `FileTransferring`, `ConnectivityMonitoring`, `ConversionRecordStoring`, `AuthorizationProvider`, `HTTPTransport`, `CloudConvertLogging`, `BackgroundActivityProviding`), so any layer can be replaced or faked.

## Configuration

Build one configuration at launch and keep one engine per background session identifier for the life of the process.

### Talking to CloudConvert directly

Fine for development, sandbox work and Mac tools. The key is in the app, so treat it as public.

```swift
CloudConvertConfiguration.direct(apiKey: key, environment: .sandbox)
```

Available environments: `.production`, `.europe`, `.unitedStates`, `.sandbox`, and `.proxy(baseURL:)`. `environment` has no default: a production key sent to the sandbox fails with `401`, and the other way round. The background session identifier defaults to `<bundle id>.cloudconvert` and the job tag to `<bundle id> <version> (<platform>)`; pass your own to keep existing ones.

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

If the key lives in a remote config store (Firebase Realtime Database, Remote Config, your own endpoint), supply a closure. The whole setup:

```swift
static let engine = ConversionEngine(configuration: .fetchingKey {
    try await RemoteAPIKey.fetch()
})
```

`RefreshableTokenAuthorization` fetches on first use and caches. Requests that need the key at the same time share one fetch. On a 401 it drops the key it sent and fetches once more, so rotating the key takes effect without an app update, and several requests refused together fetch once. When the fetch fails (the store is down, or holds no key), the conversion stops with `.authorizationFailed`, which is not retried, and the failure is reported again without fetching for `failureCooldown` seconds (10 by default). The package has no dependency on any of those SDKs.

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

Give a request a `key` (the id of the item in your app) and it becomes idempotent: `convert` continues the conversion kept for that key, after a resumable error or by a previous launch, instead of converting and billing the file again. It starts over only when that conversion can no longer finish (its job expired, its staged copy is gone). At most one conversion per key runs at a time.

```swift
var request = ConversionRequest.convert(fileURL, to: "pdf")
request.key = row.id.uuidString       // "Try again" on this row never bills twice
```

Several operations run in one job with `followUps`, without downloading in between:

```swift
var request = ConversionRequest.convert(docURL, to: "pdf")
request.followUps = [ProcessingStep(.optimize(profile: "max"))]      // convert, then compress

var photos = ConversionRequest.convert(imageURLs, to: "jpg")
photos.followUps = [ProcessingStep(.archive())]                       // one ZIP of them all
```

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

The engine runs at most `maxConcurrentConversions` (2 by default) at once, those it resumes included; the rest wait at `.preparing`. So twenty files do not create twenty jobs at once and trip the rate limit. `ConversionQueue` adds handles and ordering on top. `engine.cancel(id:)` and `engine.cancelAll()` stop conversions however they were started.

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

`retry(id:)` resumes an item whose error `isResumable` (see [Interrupted conversions](#interrupted-conversions)) instead of converting the file again. If the app already resumed it with `resumePendingConversions()`, the item follows that run, or shows its result. `remove(id:)` and `clearFinished()` discard it; `cancel(id:)` and `remove(id:)` stop it while it runs.

Apps using `@Observable` or their own architecture can use `ConversionQueue` and `ConversionHandle` directly. The view model is about 200 lines of reference code, not a requirement.

### Discovering formats and options

Option names come from the engine behind each conversion and change over time, so the API is the source of truth. `engine.catalog` keeps `/convert/formats` (with options) on disk for `catalogMaxAge` (a week), and falls back to that copy when the API can't be reached:

```swift
try await engine.catalog.supports(ConversionPair("heic", "jpg"))
try await engine.catalog.outputFormats(from: "docx")
try await engine.catalog.options(for: ConversionPair("mp4", "webm"))
try await engine.catalog.issues(in: request)      // unsupported pair, unknown option, bad value

let credits = try await engine.creditBalance()     // needs the user.read scope
```

Pairs CloudConvert offers but fails on are left out (`ConversionPair.knownFailures`: DOC and PPT to PDF, which end in `EXPORT_FAILED`); set `knownFailingConversions` to change the list. With `validatesRequests = true`, every request is checked before anything is staged or uploaded and fails with `.invalidRequest` instead of after the upload; a catalogue that can't be loaded checks nothing.

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
        BackgroundTransferManager.handleEventsForBackgroundURLSession(identifier: identifier,
                                                                      completionHandler: completionHandler)
        _ = ConversionServices.engine
    }
}
```

The handler is never dropped: one that arrives before the engine exists waits for it, and one that arrives just after the session delivered its events is called at once. The system's closure is taken as it is, also in the Swift 6 language mode.

`resumePendingConversions()` returns handles for conversions that were in flight when the app last died, so a processing screen can show them finishing. Conversions running in the current process are never reported as pending or started twice.

Background time between transfers (creating the job, polling, moving the output into place) is asked for by `SystemBackgroundActivity`, the default `backgroundActivity`: `ProcessInfo.performExpiringActivity`, the time `beginBackgroundTask` gives, without UIKit. Set `NoBackgroundActivity()` if your app manages it itself.

### Interrupted conversions

Once its job exists on CloudConvert, a conversion is never thrown away because the network or the time ran out: the job may still finish, or already has, and is paid for. When the network stays away longer than `offlineWaitTimeout` (90 s by default), or `polling.jobTimeout` passes with the job still running, the conversion stops with an error whose `isResumable` is `true`: `.timedOut(phase: .waitingForNetwork)` (also `isConnectivityRelated`) or `.jobTimedOut`. Its last stage is `.failed`; its record, staged input and job are kept, and it is listed by `pendingConversions()`.

Don't start it again, which would create a second job and bill the file twice. Resume it, for example once the device is back online:

```swift
do {
    show(try await handle.result)
} catch let error as CloudConvertError where error.isResumable {
    for await online in ConnectivityMonitor.shared.changes() where online {
        if let resumed = await engine.resumePendingConversions(where: { $0.id == handle.id }).first {
            show(try await resumed.result)
        }
        break
    }
}
```

`resumePendingConversions(where:)` resumes only the records it accepts (by `id`, `key`, or by `userInfo` for conversions your own layer started) and leaves every other record untouched. Otherwise `resumePendingConversions()` at the next launch picks it up, and `discardPendingConversion(id:)` or `discardPendingConversions(where:)` gives it up and deletes the job. `ConversionRecord.canResume` says whether a record still can (its job has not expired, its staged copies are there).

With `resumesWhenOnline = true` the engine does this itself: the conversions this process kept because the network stayed away continue when it returns. Their handles arrive through `engine.automaticResumes()` and `resumedConversion(id:)`, and `ConversionViewModel` follows them. Conversions kept by an earlier launch are left for the app to offer. A request with a `key` simply continues the kept conversion when it is converted again.

A record already running is never resumed twice, so a second caller gets no handle for it. `resumedConversion(id:)` gives that caller another handle on the run, and on its result once it has ended; it returns `nil` for one that failed for good or was cancelled, which starts over.

### macOS

Everything builds and the whole test suite runs natively. There is no `handleEventsForBackgroundURLSession` to wire, so skip that step. A background session lets a transfer survive a quit and re-attach at the next launch, but on some networks `nsurlsessiond` uploads far slower than a standard session; `usesBackgroundTransfers = false` trades that survival for speed. Sandboxed apps get security-scoped `NSOpenPanel` URLs, which staging already handles. The default `SystemBackgroundActivity` holds a `ProcessInfo` activity during a conversion, so App Nap doesn't throttle it; the Mac may still idle-sleep, and a conversion kept meanwhile continues on wake.

## Public API surface

| Area | Types | Notes |
|---|---|---|
| Orchestration | `ConversionEngine` — `convert`, `run`, `start`, `cancel(id:)`, `cancelAll`, `pendingConversions`, `resumePendingConversions`, `resumePendingConversions(where:)`, `resumedConversion(id:)`, `automaticResumes`, `discardPendingConversion`, `discardPendingConversions(where:)`, `creditBalance`, `catalog`, `availableOperations`, `apiClient` | One instance per app |
| Handles | `ConversionHandle` — `id`, `progress: AsyncStream`, `result`, `cancel()`, `isCancelled` | Returned by `start` / queue / resume |
| Batching | `ConversionQueue` — `enqueue(request)`, `enqueue(spec)`, `cancel(id:)`, `cancelAll()` | Actor; bounds concurrency |
| Requests | `ConversionRequest` (`key`, `followUps`), `ProcessingOperation`, `ProcessingStep`, `InputFile`, `ExportOptions`, `OutputOptions` | The everyday entry point |
| Catalogue | `CloudConvertCatalog`, `ConversionPair`, `CatalogIssue` | Cached formats and options |
| Job graphs | `JobBuilder`, `JobSpecification`, `TaskDefinition`, `TaskRef`, `CCOperationName` | Any CloudConvert task graph |
| Progress / result | `ConversionProgress` (+ `Stage`, `RetryScope`), `ConversionResult`, `ConvertedFile` | Sendable value types |
| Errors | `CloudConvertError` (+ `Category`), `TaskFailureCode`, `APIErrorPayload`, `ConversionPhase`, `CloudConvertLocalization` | One taxonomy for everything |
| Configuration | `CloudConvertConfiguration`, `CloudConvertEnvironment`, `RetryPolicy`, `PollingPolicy`, `ProgressWeights`, `AccountObserving`, `SystemBackgroundActivity` | All tunables in one struct |
| Endpoints | `CloudConvertAPIClient` — jobs (`create`, `get`, `list`, `delete`), tasks (`get`, `retry`, `cancel`, `delete`), `operations`, `convertFormats`, `currentUser` | `CloudConvertAPI` is the URLSession implementation |
| Models | `CCJob`, `CCTask`, `CCTaskResult`, `CCUploadForm`, `CCExportedFile`, `CCOperation`, `CCOperationOption`, `CCUser`, `CCPage`, `CCStatus`, `JSONValue` | Lenient decoding |
| Seams | `AuthorizationProvider`, `HTTPTransport`, `FileTransferring`, `ConnectivityMonitoring`, `ConversionRecordStoring`, `CloudConvertLogging`, `BackgroundActivityProviding` | Implement to replace or fake a layer |
| Persistence | `ConversionRecord`, `ConversionRecordStore`, `UnreadableRecord`, `PersistedTransfer`, `TransferOutcome` | Crash-safe state |

Progress handlers and `AsyncStream`s deliver values on arbitrary threads; hop to the main actor in your app.

## Progress model

`ConversionProgress.fractionCompleted` folds the three network phases with `ProgressWeights` (upload 45 %, processing 35 %, download 20 % by default) and never moves backwards within a job attempt. `stage` tells the UI what is happening, including `.waitingForNetwork` and `.retrying(attempt:delay:scope:reason:)`, so a screen can say "Reconnecting…" instead of freezing. Every conversion ends with exactly one terminal stage: `.completed`, `.failed` or `.cancelled`, including one cancelled while still waiting in a `ConversionQueue`. A conversion kept to resume ends with `.failed`; its error tells it apart (`isResumable`).

## Error model

Every failure is a `CloudConvertError`:

- `category` — whom to blame: `.input` (the user's file), `.unsupported` (the pair or an option), `.device` (free space), `.connectivity`, `.paused` (kept to resume), `.account` (credentials or credits: the developer's problem, not the user's), `.service` (trying again may work), `.cancelled`
- `userFacingMessage` — safe alert text, never contains URLs, text from the server or the developer (that stays in the error's associated values, for logs); `recoverySuggestion` says what to do, when there is something to say
- `isRetryable` — whether offering a "Try again" button makes sense
- `isCancellation` — show nothing, or a neutral "Cancelled" state
- `isConnectivityRelated` — show an offline banner rather than an error alert
- `isResumable` — the conversion was kept: resume it, don't start it again (see [Interrupted conversions](#interrupted-conversions))
- `analyticsCode` — stable string for analytics dashboards (`http_429`, `job_failed_invalidConversionType`, `upload_rejected_403`, …)

Messages and stage descriptions go through `CloudConvertLocalization`, with stable keys (`messageKey`); the English text is the default:

```swift
CloudConvertLocalization.setProvider { key, english in
    NSLocalizedString(key, tableName: "CloudConvertKit", value: english, comment: "")
}
```

`configuration.accountObserver` is told when a conversion stops because of the account (`isAccountProblem`), and, with `lowCreditThreshold`, when the balance runs low, so the developer hears of a revoked key or an empty account before the reviews do.

Log messages carry ids, phases and codes. File names, CloudConvert's task messages and response bodies go in the `metadata` of `CloudConvertLogging`, which the default `OSLogCloudConvertLogger` records as private.

## Edge-case matrix

| Situation | Behaviour |
|---|---|
| Device offline when a conversion starts | Not attempted; `stage == .waitingForNetwork` until the network returns or `offlineWaitTimeout` (90 s) elapses → `.notConnected`. The job is not rebuilt: it already waited the full timeout |
| Connection lost during upload or download | The background session waits for connectivity; if the task errors, the phase retries (upload 3×, download 4×) after waiting for the network. Offline waits do not consume retry attempts. The UI sees `.retrying(scope: .phase(…))`. If the network stays away longer than `offlineWaitTimeout`, the conversion is kept: see the next row |
| Connection lost while polling | Polling pauses and continues when the network returns, without counting toward the failure budget. Offline for longer than `offlineWaitTimeout`, the conversion stops with `.timedOut(phase: .waitingForNetwork)` (`isResumable`): nothing is deleted, and `resumePendingConversions()` continues it. The same applies when resuming at launch while offline |
| Requests time out while the device is online | Retried like any transient failure; an upload that keeps timing out rebuilds the job with a fresh form. Not kept as if offline |
| App backgrounded during a large upload | The upload continues in the background session |
| App backgrounded while polling | `BackgroundActivityProviding`, if wired, buys about 30 seconds; otherwise polling resumes when the app returns. Time spent suspended (or the Mac asleep) does not count toward `polling.jobTimeout`. Intervals shorter than 10 ms count as 10 ms, and a `multiplier` below 1 as 1, so the waits always reach the deadline |
| App killed mid-upload | On relaunch, `resumePendingConversions()` re-attaches to the running transfer or picks up its persisted outcome; if the transfer is gone the upload restarts against the same job when the form is still valid, otherwise the job is rebuilt. A re-attached upload that failed (5xx, network error) is retried exactly like a fresh one. Since it may have delivered the file and lost only the response, the server is asked first, before sending the file again or rebuilding the job for a form the device clock says has expired |
| App killed while the server is converting | On relaunch the job is re-fetched by id and polling continues; nothing is re-uploaded |
| App killed during download | The download is re-attached or restarted; a re-attached download that failed is retried like a fresh one; already-saved files are not fetched again |
| User force-quits the app during a transfer | iOS cancels the background transfer. That is a lost transfer, restarted at relaunch, not a user cancellation |
| `resumePendingConversions()` called twice, or while conversions run | Running conversions are never reported as pending or started twice. Each record is read again once claimed, so one that finished meanwhile is not run again. `resumedConversion(id:)` follows a resume already running |
| `resumePendingConversions(where:)` | Only the records it accepts are resumed; the others stay pending, untouched |
| Records older than 20 h | Not resumed, since the server purges jobs at 24 h; cleaned up and reported as `.jobLost` |
| 429 rate limit | `Retry-After` honoured (up to 10 minutes), falling back to backoff; the queue limits concurrent job creation |
| 5xx, malformed JSON, or HTML from a CDN | Retried with exponential backoff and jitter (5 attempts for API calls) |
| 401 | One transparent credential refresh via `AuthorizationProvider.handleUnauthorized(rejected:)`, then fails without further retries. Requests refused together with the same key fetch once |
| The key can't be fetched (store down, key missing) | `.authorizationFailed` (category `.account`), not retried; the fetch is not repeated for `failureCooldown` |
| 402 (credits), 403, 422 | Not retried; specific error cases with safe user text |
| Upload form expired, or storage returned 4xx | The whole job is rebuilt with a fresh form, once by default. The device clock may be wrong, so it only judges forms a previous launch received, and only while a rebuild is still allowed |
| Storage returned 5xx on upload | The same request is retried against the same form |
| Task error `TIMEOUT`, `INPUT_TASK_FAILED`, or an unknown code | Job rebuilt once |
| Task error `INVALID_CONVERSION_TYPE`, `CONVERSION_FAILED`, `OPEN_FAILED`, `SANDBOX_FILE_NOT_ALLOWED`, `FILE_TOO_LARGE`, `EXPORT_FAILED`, `UNKNOWN_ERROR` | Not retried, since it would only burn credits; the user gets a specific message |
| Offline during a background transfer | The session waits by itself; the stage reports `.waitingForNetwork` meanwhile, and goes back when the network does |
| A record a release can't read | Removed at engine init, with its job and files |
| Job disappears (404) | `.jobLost`, rebuilt once |
| Job stuck in `processing` past `polling.jobTimeout` | Checked once more; if still running, `.jobTimedOut` (`isResumable`): the job and the record are kept for `resumePendingConversions()` |
| Finished job with no exported files | `.exportMissing`, not retried |
| Multiple exported files | All downloaded, or one zip via `ExportOptions.archiveMultipleFiles`. If the conversion fails, the files it had already saved are removed |
| Export URL expired (403/404/410 on download) | Treated as `.jobLost`, so the job is rebuilt once |
| Downloaded file is empty | Retried as a download failure, unless the server reported the output as 0 bytes |
| Input missing, unreadable, empty, or over the size limit | Fails locally before any network call |
| Input larger than the form's `max_file_size` | Fails before uploading |
| Not enough disk space | `.insufficientDiskSpace` while staging the input; before uploading when there is no room for the largest upload body or the expected outputs; and again before downloading with the real size |
| Output filename collision | `name (2).ext`, `name (3).ext`, … |
| Filenames with quotes, slashes or control characters | Sanitised for both the multipart header and the file system |
| Document-picker or Photos URLs | Security scope handled; the file is copied via `NSFileCoordinator` into the package's staging directory |
| Large files | The staging copy and the multipart body are written in 1 MiB chunks on a dedicated IO queue, never in memory and never on a Swift-concurrency thread |
| User cancels, in any phase including the delay before a rebuild, while queued, or while waiting for the network | URLSession tasks cancelled, temporary files removed, server job deleted, record removed, exactly one `.cancelled` stage. A cancellation is never kept to resume, even when the network wait gives up at that moment |
| Success | The server job is deleted immediately for privacy, temporary files removed, record removed. Outputs are saved readable by everyone (0644), not URLSession's 0600 |
| Crash leaving temporary files behind | Anything older than 48 h is purged at engine init |
| Unknown future job or task status string | Decoded as `processing` so polling continues instead of crashing |
| Odd catalogue rows (booleans as 0/1, numbers as strings) | Models decode leniently; one odd row never breaks the list |
| Absurd values from the server or a proxy (`Retry-After: inf`, `credits: 1e20`, sizes near `Int64.max`) | Capped or treated as unknown; nothing traps |
| Export URL with a space, non-ASCII characters or a `#` inside the fragment | Decoded the same on every supported OS (invalid characters percent-encoded), never dropped |
| `percent` reported by the server | Used for the processing phase; otherwise a time-based estimate that never reaches 100 % early |
| Metered connections | `allowsCellularTransfers = false` restricts transfers to Wi-Fi |
| On-demand VPN (path `requiresConnection`) | Counts as online, so the request that brings the VPN up is made |
| Two engines created at once for one background session identifier | They share one transfer manager, so one background session |

## Proxy contract

`CloudConvertEnvironment.proxy(baseURL:)` points the JSON API calls at your server, which must:

1. Expose the same paths under its base URL: `POST /jobs`, `GET /jobs`, `GET /jobs/{id}`, `DELETE /jobs/{id}`, `GET /tasks/{id}`, `POST /tasks/{id}/retry`, `POST /tasks/{id}/cancel`, `DELETE /tasks/{id}`, and optionally `GET /operations`, `GET /convert/formats`, `GET /users/me`.
2. Forward the request body and query string unchanged to `https://api.cloudconvert.com/v2/…` (or a regional host) with `Authorization: Bearer <API key>` added server-side.
3. Return CloudConvert's status code and JSON body unchanged, **including** the `Retry-After`, `X-RateLimit-Limit` and `X-RateLimit-Remaining` headers, which the package reads.
4. Authenticate the app however you like. The package sends whatever `AuthorizationProvider` returns as the `Authorization` header plus `additionalHeaders()`; on a 401 it calls `handleUnauthorized(rejected:)` once and retries with fresh credentials.

Uploads (`upload.cloudconvert.com`) and downloads (`storage.cloudconvert.com`) go directly to CloudConvert storage using the pre-signed form and URLs from the job response, so the proxy never carries file bytes.

Optionally the proxy can enforce per-user quotas, strip `webhook_url`, force a `tag`, or restrict operations. It must not alter task names or the `result.form` object.

## File locations

Everything lives under `Application Support/<bundle id>/CloudConvertKit/`: `Work/` for staging, multipart bodies, in-flight downloads and records, and `Converted/` for outputs. Application Support is app-private on both platforms, so nothing lands in a user-visible folder on macOS, and the bundle-identifier segment keeps unsandboxed Mac apps apart. Override `outputDirectory` per configuration or `OutputOptions.directory` per request. `Work/` is excluded from backups; `Converted/` is not.

During a conversion the package holds up to two extra copies of the input on disk: the staged copy, and the multipart body of the input being uploaded (deleted after its upload). A disk that fills up while staging is reported as `.insufficientDiskSpace`. After staging, the pre-flight check requires room for the larger of the biggest upload body and the expected outputs (`OutputOptions.expectedOutputBytes`, otherwise twice the inputs).

The package ships a privacy manifest (`PrivacyInfo.xcprivacy`) declaring the required-reason APIs it calls: the modification dates of its own temporary files, to purge stale ones, and free disk space, for that check. Nothing is collected or tracked.

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

The suite runs entirely against in-memory fakes for the API, the transfer layer and connectivity, the ones `CloudConvertKitTesting` ships. It covers the happy path, output naming, multi-file export, deterministic versus transient failure handling, upload rejection leading to a job rebuild, storage 5xx retrying against the same form, offline timeouts, cancellation cleanup both mid-upload and during a rebuild delay, resuming from a persisted record without re-uploading, running conversions being excluded from "pending", conversions kept when the network or the polling deadline runs out and resumed later, re-attached transfers that failed or were cancelled by the system, a resume followed by a second caller or by the SwiftUI model, queue concurrency, retry and backoff arithmetic, values from the server that must not trap, error mapping, and model decoding.

Tests are grouped by subject: `ErrorTests`, `DecodingTests`, `RequestTests`, `NetworkingTests`, `TransferTests`, `EngineTests`, `ResumeTests`, `CatalogTests`, `ViewModelTests` and `StressTests`, with shared helpers in `TestSupport`. The helpers that wait on asynchronous work (`waitUntil`, `withTimeout`) give up after a limit, so a regression fails instead of hanging the suite.

`Tests/CloudConvertKitTests/Fixtures/` holds real `GET /v2/jobs/{id}` responses (a finished job and a failed one, signed URLs redacted). The regression tests run them through the real `CloudConvertAPI` decoder, and the fakes follow the same shapes: only export tasks list files with a `url`, and an engine that cannot convert a file reports `code: null`.

`StressTests` runs 150 conversions at once against a simulated CloudConvert with seeded faults at every layer, including cancellation at random moments and networks that drop once the input is uploaded. It resumes the conversions that were kept, once the network is back, then checks that every conversion ends exactly once, that no file is billed twice, that exactly the conversions that may still be billed were kept, that every known job is deleted and that no local state is left. Each run prints its seed; replay one or scale up with:

```bash
CCK_STRESS_SEED=1790701569452 CCK_STRESS_COUNT=1000 swift test --filter StressTests
```

Run the suite under Thread Sanitizer with `swift test --sanitize=thread`. Codesign rejects test bundles built under `~/Documents` (Finder metadata), so build elsewhere there: `swift test --scratch-path /tmp/cck-build`.

For a live smoke test use `CloudConvertConfiguration.direct(apiKey:environment: .sandbox)` with a file whitelisted in the CloudConvert sandbox dashboard.

`CloudConvertKitSwift6Tests` builds in the Swift 6 language mode, using the kit as an app does.

## Migrating from 1.x

- **Toolchain:** Swift 6 (Xcode 16+). Platforms are unchanged.
- **`direct(apiKey:environment:)`** takes no default environment any more; pass one.
- **`AuthorizationProvider.handleUnauthorized()`** is now `handleUnauthorized(rejected:)`, with the refused `Authorization` value. A custom provider that implemented the old one must rename it, or it silently gets the default (`false`: no refresh).
- **`setBackgroundCompletionHandler`** takes a plain `() -> Void`. Prefer `BackgroundTransferManager.handleEventsForBackgroundURLSession(identifier:completionHandler:)`, which keeps a handler that arrives before the engine.
- **`maxConcurrentConversions`** is applied by the engine to every conversion (it was the queue's default only). An app that relied on running more at once raises it.
- **`backgroundActivity`** defaults to `SystemBackgroundActivity()`; a UIKit adapter of your own still works, or set `NoBackgroundActivity()`.
- **New `CloudConvertError.authorizationFailed`** and **`TaskFailureCode.exportFailed` / `.unknownError`**: an exhaustive `switch` needs the cases.
- **`invalidRequest`'s message** no longer includes the reason; it stays in the associated value.
- **`analyticsCode` for task failures** is `job_failed_<code>` with the case name as before (`job_failed_exportFailed`); codes the kit didn't know in 1.x (`EXPORT_FAILED`, `UNKNOWN_ERROR`) were `job_failed_export_failed` / `job_failed_unknown_error`.
- Messages are unchanged in English; route them through `CloudConvertLocalization` to translate.

## Contributing

Issues and pull requests are welcome. Please keep the core free of third-party dependencies and of UI framework imports, and add a test alongside any behaviour change.

## License

MIT. See [LICENSE](LICENSE).

This is an independent project and is not affiliated with or endorsed by CloudConvert.

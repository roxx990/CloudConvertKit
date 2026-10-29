# Changelog

## 2.0.0

Fixes and additions from running the kit in production apps, on iOS and macOS. Breaking changes are listed under **Migrating from 1.x** in the README; in short: a Swift 6 toolchain, `direct(apiKey:environment:)` without a default environment, `handleUnauthorized(rejected:)`, `maxConcurrentConversions` applied by the engine, and new error cases.

**Fixes**
- **An upload no longer holds the file in memory.** `MultipartFormWriter` copied the file into the upload body in chunks that iOS's Foundation leaves for the thread's autorelease pool, which didn't drain until the whole file was copied. Each chunk is now freed as it goes: a 200 MB file held 198 MB on the iOS simulator, now almost nothing.
- **A key that can't be fetched is no longer a server hiccup.** A failing `AuthorizationProvider` (the key store down, or empty) was wrapped as `.invalidResponse`, retried five times with a fetch each, then shown as "the service is having trouble". It is now `.authorizationFailed`: not retried, category `.account`.
- **The background completion handler is never dropped.** One that arrived before the engine existed, or just after the session delivered its events, was lost and the system's handler never called. `BackgroundTransferManager.handleEventsForBackgroundURLSession(identifier:completionHandler:)` keeps it for the manager, and a late one is called at once. It takes UIKit's closure as it is, also in Swift 6.
- **`RefreshableTokenAuthorization` fetches once.** Requests that need the key together share one fetch; a 401 drops the key only if it is the one refused, so requests refused together re-fetch once; a failed fetch is reported again without fetching for `failureCooldown` (10 s).
- **"Waiting for network" during background transfers.** The session waits for the network by itself, so the stage stayed `.uploading`; it now reports `.waitingForNetwork` while offline.
- **Credits are kept for a conversion resumed with only its downloads left** (`ConversionResult.credits` was nil).
- **Outputs are saved 0644**, not URLSession's 0600.
- **Resumed conversions count toward `maxConcurrentConversions`**, and `cancelAll()` reaches them.
- **`outputFormatHint` follows the task feeding the export**, not the first processing task, so a multi-step job names and estimates its output by what it exports.
- **Records a release can't read are cleaned up** (job deleted, files removed) instead of staying forever. Records carry a `formatVersion`.
- `invalidRequest`'s message no longer shows developer text. The User-Agent carries the kit's real version.

**Added**
- **Error categories:** `CloudConvertError.category` (`.input`, `.unsupported`, `.device`, `.connectivity`, `.paused`, `.account`, `.service`, `.cancelled`), `isAccountProblem`, `recoverySuggestion`, `messageKey`.
- **Localization:** `CloudConvertLocalization.setProvider`, with stable keys for every message and stage description.
- **Task codes:** `EXPORT_FAILED` and `UNKNOWN_ERROR` are `.exportFailed` and `.unknownError`, not retried.
- **Account observer:** `configuration.accountObserver` (`AccountObserving`) hears of account problems, and of a balance below `lowCreditThreshold`. `engine.creditBalance(maxAge:)`.
- **Idempotent requests:** `ConversionRequest.key` continues the conversion kept for that key instead of billing the file again, and starts over only when it can no longer finish.
- **Automatic resume:** `resumesWhenOnline` continues the conversions this process kept when the network returns; `engine.automaticResumes()`; `ConversionViewModel` follows them.
- **Resume helpers:** `ConversionRecord.canResume`, `isExpired()`, `key`; `discardPendingConversions(where:)`; `ConversionEngine.maxResumableAge`.
- **Control:** `engine.cancel(id:)` and `engine.cancelAll()` for conversions however they were started.
- **Catalogue:** `CloudConvertCatalog` (`engine.catalog`): `/convert/formats` with options, cached on disk for `catalogMaxAge`, used when the API can't be reached; `supports`, `engines`, `options`, `outputFormats`, `options(forOperation:)`, `issues(in:)`. Known failing pairs (`ConversionPair.knownFailures`: DOC and PPT to PDF) are left out. `validatesRequests` checks every request before anything is uploaded; a pair or operation the catalogue lists without options is not judged.
- **Multi-step jobs:** `ConversionRequest.followUps` (`ProcessingStep`): convert then optimize, each file then one archive, in one job.
- **Setup:** `CloudConvertConfiguration.fetchingKey { … }`; default session identifier `<bundle id>.cloudconvert` and job tag `<bundle id> <version> (<platform>)`.
- **Background activity without UIKit:** `SystemBackgroundActivity`, the default: a `ProcessInfo` activity on macOS, `performExpiringActivity` on iOS.
- **`CloudConvertKitTesting`:** `FakeCloudConvertAPI`, `FakeFileTransfers`, `FakeConnectivity`, `AlwaysOnline`, `AlwaysOffline`.
- **Swift 6:** strict concurrency checking on every target, and `CloudConvertKitSwift6Tests` in the Swift 6 language mode.
- Tests: 175, on macOS, the iOS simulator and under Thread Sanitizer, grouped by subject; duplicates removed and timing-based assertions replaced by exact ones.

## 1.1.0

Fixes from two independent reviews. Three additions to the public API: `CloudConvertError.isResumable`, `ConversionEngine.resumePendingConversions(where:)` and `ConversionEngine.resumedConversion(id:)`. Nothing was removed or renamed, and `CloudConvertError` has no new cases.

### Paid conversions are kept, not deleted
- **A conversion whose job may still finish is kept.** When the network stays away longer than `offlineWaitTimeout` after the job was created (resuming at launch included), or `polling.jobTimeout` passes with the job still running, the record and the job are kept and the conversion throws `.timedOut(phase: .waitingForNetwork)` or `.jobTimedOut`. Both report `isResumable`, and `resumePendingConversions()` continues the conversion where it stopped. Neither is `isRetryable`, since starting the conversion again would bill it twice; the first is `isConnectivityRelated`. Previously the job was deleted, so a conversion that had finished and been billed was lost. A request that merely timed out while the device was online is retried as before, and during an upload the job is rebuilt, as in 1.0.1.
- **The polling deadline no longer counts time the app was suspended or the Mac asleep**, and the job is always checked once more before giving up, so one that finished meanwhile is downloaded. Since only the waits between checks count, an interval shorter than 10 ms counts as 10 ms and a `multiplier` below 1 as 1: the waits always add up to `jobTimeout`.
- **`resumePendingConversions(where:)` resumes only the records it accepts** and leaves the others untouched: not started, not marked as running, still pending.
- **`resumedConversion(id:)` follows a conversion `resumePendingConversions` started**, while it runs and once it has ended: another handle with its progress from the latest stage on, its result and `cancel()`. It returns `nil` for one that failed for good or was cancelled. Something that shows a conversion the app may also have resumed itself follows that run instead of converting the file again.
- **A record is read again once it is claimed for a resume**, so one that finished between being listed and being claimed is not run again from its old copy.

### Transfers re-attached after a relaunch
- **A re-attached upload or download is retried like a fresh one.** A 5xx or a network error goes through the phase's retry policy, against the same form or URL. Previously a 5xx on a re-attached download failed the conversion and deleted its job, a 503 on an upload rebuilt the job, and a network error failed it. A re-attached upload may have delivered the file and lost only the response, so before the file is sent again, or the job rebuilt because the device clock says the form expired, the server is asked whether it arrived.
- **A transfer the system cancelled is restarted, not taken for a user cancellation.** iOS cancels background transfers when the user force-quits the app; only a cancellation the engine asked for is `.cancelled`, including one that arrives just as the transfer starts.

### Crashes and a stuck offline state
- **Values from the server or a proxy can no longer crash the app.** `Retry-After: inf`, `1e30` or a date in year 9999, `credits` of `"inf"` or `1e20`, and sizes near `Int64.max` used to trap. `Retry-After` is now capped at 10 minutes.
- **The connectivity monitor applies network changes in order.** An update applied out of order could leave it reporting offline, and refusing every request, while the device was online. A path that `requiresConnection` (an on-demand VPN) now counts as online, so the request that brings it up is made.
- **Engines created at the same moment for one background session identifier share one session.** Each could create its own, with the same identifier.

### Smaller fixes
- A multi-file conversion that fails removes the files it had already saved, and so does `discardPendingConversion(id:)`.
- Cancelling while the engine asks the server whether an upload arrived is a cancellation, not a failure; so is cancelling while the engine waits for the network, even if the wait gives up at that moment. The conversion is cleaned up, not kept.
- A conversion cancelled while still queued in `ConversionQueue` ends with a `.cancelled` stage.
- A 404 from that arrival check rebuilds the job (`.jobLost`) instead of failing with `.notFound`.
- An output the server reports as 0 bytes is accepted instead of retried and failed.
- Export URLs with a space, non-ASCII characters or a `#` inside the fragment decode on iOS 15/16 and macOS 12/13 as they do on later systems, instead of the file being dropped.
- A device clock running ahead no longer fails every upload: the clock only judges forms a previous launch received, and only while a new job is still allowed.
- Staging an input on a full disk reports `.insufficientDiskSpace`, not `.fileNotReadable`. With `expectedOutputBytes` set, the free-space check before uploading also counts the upload body.

### Privacy
- **The default logger keeps user content private.** File names, CloudConvert's task messages and response bodies are passed as metadata, which `OSLogCloudConvertLogger` records as private. Custom loggers receive them in `metadata`.
- **`userFacingMessage` no longer quotes the server** for `.validation` and `.jobFailed`, as its documentation always said. The server's text stays in the error's associated values.
- **A privacy manifest** (`PrivacyInfo.xcprivacy`) declares the required-reason APIs the package calls: file timestamps of its own temporary files (to purge stale ones) and disk space (to refuse a conversion that wouldn't fit). Nothing is collected or tracked.

### CloudConvertKitUI
- `ConversionViewModel.retry(id:)` resumes an item whose error `isResumable` instead of converting the file again. If the app resumed it itself (`resumePendingConversions()`), the item follows that run, or shows its result. `remove(id:)` and `clearFinished()` discard it.
- `cancel(id:)`, `cancelAll()` and `remove(id:)` reach an item `retry(id:)` resumed, including one whose resume is still starting.
- An item shows `.failed` only together with its error, so `retry(id:)` cannot take a kept conversion for a failed one and convert it again.

## 1.0.1

Bug fixes found by running against the live CloudConvert API. No public API changes.

### Conversions that never completed or were billed twice
- **Finished jobs now decode.** CloudConvert lists `convert` and `import/upload` task files without a `url`, which made every finished job fail to decode. Files without a `url` are now left out of `CCTaskResult.files`. A task `result` of an unexpected shape, and odd task timestamps or `credits`, no longer fail the whole job.
- **An unreadable response no longer rebuilds the job.** A `.decoding` or `.invalidResponse` error retries the request but never starts a new job (a new upload and a new billed conversion). Once every input is uploaded, transport errors (5xx, timeouts, rate limits) fail the conversion instead of rebuilding it. Once downloading has started, nothing rebuilds.
- **A file CloudConvert cannot convert is tried once.** A failed processing task with `code: null` is `.conversionFailed` (not retryable). Unknown failure codes (`.other`) are no longer retryable either.
- **A lost upload response no longer leads to a second upload.** Before re-sending an upload, and before rebuilding after an upload failure, the engine asks CloudConvert whether the file arrived. If it did, the engine goes on to poll the same job.
- **`POST /jobs` is only repeated when it is safe.** For a job that starts by itself (`import/url`), creation is re-sent only when the request provably never reached the server. `retryTask` follows the same rule.
- **Resuming does not rebuild a job that may be converting.** The resumed job's saved phase is kept when its status can't be fetched.

### Jobs left on CloudConvert
- **Cancelling while the job is being created deletes the job.** The request runs to completion in the background and the job it creates is deleted. The caller still gets `.cancelled` straight away.
- **Jobs without upload forms, and jobs whose create response can't be decoded, are deleted.**

### Local files
- **Two inputs with the same file name no longer overwrite each other in staging.** This affected merges, for example of two `image.jpeg` files.
- **Conversions finishing at the same time never write to the same output file.** Previously two same-named outputs could both report success while one replaced the other.

### Robustness
- **Polling backs off when the host is unreachable** (captive portal, proxy down) instead of looping without delay.
- **A transfer that failed while the app was not running is restarted** instead of failing the phase.
- **No progress update arrives after the final stage** (`.completed`, `.failed` or `.cancelled`).
- **`discardPendingConversion(id:)` does nothing for a conversion that is still running.** Cancel its handle instead.

### Documentation
- **`CloudConvertConfiguration.direct(...)` defaults `environment` to `.sandbox`.** A production key used against the sandbox is rejected with 401. Always pass `environment:`. The default will be removed in 2.0.

# Edge cases

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

## Situation by situation

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

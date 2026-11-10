# Converting

## Requests

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

## Observing instead of awaiting

```swift
let handle = engine.start(request)
Task { for await progress in handle.progress { await MainActor.run { model.progress = progress } } }
let result = try await handle.result
handle.cancel()
```

## Arbitrary task graphs

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

## Batching

The engine runs at most `maxConcurrentConversions` (2 by default) at once, those it resumes included; the rest wait at `.preparing`. So twenty files do not create twenty jobs at once and trip the rate limit. `ConversionQueue` adds handles and ordering on top. `engine.cancel(id:)` and `engine.cancelAll()` stop conversions however they were started.

```swift
let queue = ConversionQueue(engine: engine, maxConcurrent: 2)
let handles = await queue.enqueue(requests)
await queue.cancelAll()
```

## Discovering formats and options

Option names come from the engine behind each conversion and change over time, so the API is the source of truth. `engine.catalog` keeps `/convert/formats` (with options) on disk for `catalogMaxAge` (a week), and falls back to that copy when the API can't be reached:

```swift
try await engine.catalog.supports(ConversionPair("heic", "jpg"))
try await engine.catalog.outputFormats(from: "docx")
try await engine.catalog.options(for: ConversionPair("mp4", "webm"))
try await engine.catalog.issues(in: request)      // unsupported pair, unknown option, bad value

let credits = try await engine.creditBalance()     // needs the user.read scope
```

Pairs CloudConvert offers but fails on are left out (`ConversionPair.knownFailures`: DOC and PPT to PDF, which end in `EXPORT_FAILED`); set `knownFailingConversions` to change the list. With `validatesRequests = true`, every request is checked before anything is staged or uploaded and fails with `.invalidRequest` instead of after the upload; a catalogue that can't be loaded checks nothing.

## Progress

`ConversionProgress.fractionCompleted` folds the three network phases with `ProgressWeights` (upload 45 %, processing 35 %, download 20 % by default) and never moves backwards within a job attempt. `stage` tells the UI what is happening, including `.waitingForNetwork` and `.retrying(attempt:delay:scope:reason:)`, so a screen can say "Reconnecting…" instead of freezing. Every conversion ends with exactly one terminal stage: `.completed`, `.failed` or `.cancelled`, including one cancelled while still waiting in a `ConversionQueue`. A conversion kept to resume ends with `.failed`; its error tells it apart (`isResumable`).

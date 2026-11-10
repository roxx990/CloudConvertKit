# Architecture

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

## Public API

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

## Design decisions

- **Polling rather than the sync API or sockets.** A long-lived HTTP request is the least reliable thing on a phone. Polling with a growing interval (1 s → 6 s) survives app switches and cellular handovers, and the request volume is negligible.
- **One job per file for conversions, one job per batch for merge and archive.** A single bad file cannot fail a whole batch.
- **Job-level retry rebuilds the whole job** rather than calling `POST /tasks/{id}/retry`. It costs a re-upload but does not depend on server-side retry semantics that are undocumented for chained tasks.
- **Inputs are staged.** Copying doubles temporary disk use for the duration of a conversion, but makes the pipeline immune to the source disappearing and lets background sessions read the file.
- **Validation and disk-space checks happen before any credit is spent.**
- **Records persist as JSON files** rather than a database; there are only ever a handful of them.
- **Platform glue is injected**, so the core stays platform-neutral and fully testable.

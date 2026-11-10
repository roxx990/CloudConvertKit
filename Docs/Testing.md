# Testing

```bash
swift test
```

The suite runs entirely against in-memory fakes for the API, the transfer layer and connectivity, the ones `CloudConvertKitTesting` ships, with no network. 171 tests run on macOS in about 15 seconds: 168 in `CloudConvertKitTests` and three in `CloudConvertKitSwift6Tests`, which builds in the Swift 6 language mode and uses the kit as an app does.

On an iOS simulator:

```bash
xcodebuild test -scheme CloudConvertKit-Package -destination 'platform=iOS Simulator,name=iPhone 17'
```

Under Thread Sanitizer: `swift test --sanitize=thread`. Codesign rejects test bundles built under `~/Documents` (Finder metadata), so build elsewhere there: `swift test --scratch-path /tmp/cck-build`.

For a live smoke test use `CloudConvertConfiguration.direct(apiKey:environment: .sandbox)` with a file whitelisted in the CloudConvert sandbox dashboard.

## What each file covers

| File | Covers |
|---|---|
| `PipelineTests` | A conversion end to end: outputs, names, multi-file exports, what fails before the upload or after the server, and what stays out of logs |
| `FailureHandlingTests` | What each failure leads to: the same job tried again, a new job, or the end, so nothing is billed twice |
| `CancellationTests` | Cancelling in every phase, while waiting for a slot and while queued |
| `ResumeTests` | Conversions kept when the network or the polling deadline runs out, resumed in this process, after a relaunch and from every phase; following and discarding them |
| `EngineControlTests` | Concurrency limits, keyed requests, checks against the catalogue, the account observer, records a release can't read |
| `RealAPIClientTests` | The engine with the real `CloudConvertAPI` over a scripted transport, on the real job responses in `Fixtures/` |
| `TransferTests` | The background transfer manager, the session handoff, re-attaching to transfers a previous launch started, background time |
| `NetworkingTests` | Retry and backoff arithmetic, `Retry-After`, credentials, the cancellation shield, connectivity |
| `RequestTests` | Requests into job specifications, follow-up steps, multipart upload bodies |
| `DecodingTests` | Lenient models, the real job responses, values that must not trap, URLs on every OS |
| `ErrorTests` | Error classification, categories, user-facing text and its localization |
| `StorageTests` | Output names, collisions, the free space a conversion needs |
| `CatalogTests` | The formats catalogue: pairs, known failures, option checks, caching |
| `ViewModelTests` | `ConversionViewModel`, retrying and cancelling items the engine resumes |
| `StressTests` | The randomised end-to-end run below |

`Support/` holds what they share: `EngineTestCase`, the base of the engine's tests (the fakes and directories of its own, an `engine` made on first use from `configuration`); the fakes the tests add (`Fakes.swift`); synchronisation and waiting (`Helpers.swift`); files, fixtures, the test configuration and `seedPreviousLaunch`, a conversion a previous launch left behind (`Fixtures.swift`). The helpers that wait on asynchronous work (`waitUntil`, `withTimeout`) give up after a limit, so a regression fails instead of hanging the suite.

`Fixtures/` holds real `GET /v2/jobs/{id}` responses (a finished job and a failed one, signed URLs redacted). The tests run them through the real `CloudConvertAPI` decoder, and the fakes follow the same shapes: only export tasks list files with a `url`, and an engine that cannot convert a file reports `code: null`.

## Stress test

`StressTests` runs 150 conversions at once against a simulated CloudConvert with seeded faults at every layer, including cancellation at random moments and networks that drop once the input is uploaded. It resumes the conversions that were kept, once the network is back, then checks that every conversion ends exactly once, that no file is billed twice, that exactly the conversions that may still be billed were kept, that every known job is deleted and that no local state is left. Each run prints its seed; replay one or scale up with:

```bash
CCK_STRESS_SEED=1790701569452 CCK_STRESS_COUNT=1000 swift test --filter StressTests
```

## CI

[`.github/workflows/tests.yml`](../.github/workflows/tests.yml) runs the suite on every push to `main` and every pull request:
- on macOS;
- on macOS under Thread Sanitizer;
- on the newest iPhone simulator the runner has;
- built for an iOS device and for Mac Catalyst, which can't run it there.

A failed `StressTests` run prints its seed in the log; replay it locally with `CCK_STRESS_SEED`.

# Changelog

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

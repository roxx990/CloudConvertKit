# Migrating from 1.x

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

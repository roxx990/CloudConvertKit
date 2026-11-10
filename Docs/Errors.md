# Errors

Every failure is a `CloudConvertError`:

- `category` — whom to blame: `.input` (the user's file), `.unsupported` (the pair or an option), `.device` (free space), `.connectivity`, `.paused` (kept to resume), `.account` (credentials or credits: the developer's problem, not the user's), `.service` (trying again may work), `.cancelled`
- `userFacingMessage` — safe alert text, never contains URLs, text from the server or the developer (that stays in the error's associated values, for logs); `recoverySuggestion` says what to do, when there is something to say
- `isRetryable` — whether offering a "Try again" button makes sense
- `isCancellation` — show nothing, or a neutral "Cancelled" state
- `isConnectivityRelated` — show an offline banner rather than an error alert
- `isResumable` — the conversion was kept: resume it, don't start it again (see [Interrupted conversions](App-Lifecycle.md#interrupted-conversions))
- `analyticsCode` — stable string for analytics dashboards (`http_429`, `job_failed_invalidConversionType`, `upload_rejected_403`, …)

Messages and stage descriptions go through `CloudConvertLocalization`, with stable keys (`messageKey`); the English text is the default:

```swift
CloudConvertLocalization.setProvider { key, english in
    NSLocalizedString(key, tableName: "CloudConvertKit", value: english, comment: "")
}
```

`configuration.accountObserver` is told when a conversion stops because of the account (`isAccountProblem`), and, with `lowCreditThreshold`, when the balance runs low, so the developer hears of a revoked key or an empty account before the reviews do.

Log messages carry ids, phases and codes. File names, CloudConvert's task messages and response bodies go in the `metadata` of `CloudConvertLogging`, which the default `OSLogCloudConvertLogger` records as private.

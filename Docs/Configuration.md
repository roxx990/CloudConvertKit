# Configuration

Build one configuration at launch and keep one engine per background session identifier for the life of the process.

## Talking to CloudConvert directly

Fine for development, sandbox work and Mac tools. The key is in the app, so treat it as public.

```swift
CloudConvertConfiguration.direct(apiKey: key, environment: .sandbox)
```

Available environments: `.production`, `.europe`, `.unitedStates`, `.sandbox`, and `.proxy(baseURL:)`. `environment` has no default: a production key sent to the sandbox fails with `401`, and the other way round. The background session identifier defaults to `<bundle id>.cloudconvert` and the job tag to `<bundle id> <version> (<platform>)`; pass your own to keep existing ones.

## Through your own backend (recommended for shipping apps)

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

## Fetching the key at runtime

If the key lives in a remote config store (Firebase Realtime Database, Remote Config, your own endpoint), supply a closure. The whole setup:

```swift
static let engine = ConversionEngine(configuration: .fetchingKey {
    try await RemoteAPIKey.fetch()
})
```

`RefreshableTokenAuthorization` fetches on first use and caches. Requests that need the key at the same time share one fetch. On a 401 it drops the key it sent and fetches once more, so rotating the key takes effect without an app update, and several requests refused together fetch once. When the fetch fails (the store is down, or holds no key), the conversion stops with `.authorizationFailed`, which is not retried, and the failure is reported again without fetching for `failureCooldown` seconds (10 by default). The package has no dependency on any of those SDKs.

Persist the last good key in the Keychain inside your fetcher so an outage or a cold start without network does not block a conversion. Note this improves on hardcoding (instant rotation, nothing in the binary) but the key still reaches the device, so it is not a substitute for a proxy.

## Proxy contract

`CloudConvertEnvironment.proxy(baseURL:)` points the JSON API calls at your server, which must:

1. Expose the same paths under its base URL: `POST /jobs`, `GET /jobs`, `GET /jobs/{id}`, `DELETE /jobs/{id}`, `GET /tasks/{id}`, `POST /tasks/{id}/retry`, `POST /tasks/{id}/cancel`, `DELETE /tasks/{id}`, and optionally `GET /operations`, `GET /convert/formats`, `GET /users/me`.
2. Forward the request body and query string unchanged to `https://api.cloudconvert.com/v2/…` (or a regional host) with `Authorization: Bearer <API key>` added server-side.
3. Return CloudConvert's status code and JSON body unchanged, **including** the `Retry-After`, `X-RateLimit-Limit` and `X-RateLimit-Remaining` headers, which the package reads.
4. Authenticate the app however you like. The package sends whatever `AuthorizationProvider` returns as the `Authorization` header plus `additionalHeaders()`; on a 401 it calls `handleUnauthorized(rejected:)` once and retries with fresh credentials.

Uploads (`upload.cloudconvert.com`) and downloads (`storage.cloudconvert.com`) go directly to CloudConvert storage using the pre-signed form and URLs from the job response, so the proxy never carries file bytes.

Optionally the proxy can enforce per-user quotas, strip `webhook_url`, force a `tag`, or restrict operations. It must not alter task names or the `result.form` object.

## Files on disk

Everything lives under `Application Support/<bundle id>/CloudConvertKit/`: `Work/` for staging, multipart bodies, in-flight downloads and records, and `Converted/` for outputs. Application Support is app-private on both platforms, so nothing lands in a user-visible folder on macOS, and the bundle-identifier segment keeps unsandboxed Mac apps apart. Override `outputDirectory` per configuration or `OutputOptions.directory` per request. `Work/` is excluded from backups; `Converted/` is not.

During a conversion the package holds up to two extra copies of the input on disk: the staged copy, and the multipart body of the input being uploaded (deleted after its upload). A disk that fills up while staging is reported as `.insufficientDiskSpace`. After staging, the pre-flight check requires room for the larger of the biggest upload body and the expected outputs (`OutputOptions.expectedOutputBytes`, otherwise twice the inputs).

The package ships a privacy manifest (`PrivacyInfo.xcprivacy`) declaring the required-reason APIs it calls: the modification dates of its own temporary files, to purge stale ones, and free disk space, for that check. Nothing is collected or tracked.

//  Everything tunable lives here so each app can build one configuration at
//  launch and inject it. Nothing in the kit reads global state.
//

import Foundation

/// Where API requests are sent. Uploads and downloads never go through this
/// host: the upload form URL and export URLs returned by the API point directly
/// at CloudConvert storage.
public enum CloudConvertEnvironment: Equatable, Sendable {
    /// Direct: `https://api.cloudconvert.com/v2`. Requires an API key on device.
    case production
    /// Direct EU region: `https://eu-central.api.cloudconvert.com/v2`.
    case europe
    /// Direct US region: `https://us-east.api.cloudconvert.com/v2`.
    case unitedStates
    /// Direct sandbox: unlimited jobs, only whitelisted files.
    case sandbox
    /// Your own backend that forwards the CloudConvert v2 REST surface and holds
    /// the API key. See README → "Proxy contract".
    case proxy(baseURL: URL)

    public var baseURL: URL {
        switch self {
        case .production: return URL(string: "https://api.cloudconvert.com/v2")!
        case .europe: return URL(string: "https://eu-central.api.cloudconvert.com/v2")!
        case .unitedStates: return URL(string: "https://us-east.api.cloudconvert.com/v2")!
        case .sandbox: return URL(string: "https://sandbox.api.cloudconvert.com/v2")!
        case .proxy(let baseURL): return baseURL
        }
    }

    public var isSandbox: Bool {
        if case .sandbox = self { return true }
        return false
    }
}

/// How long to keep polling a job and how aggressively.
public struct PollingPolicy: Equatable, Sendable {
    /// Delay before the first status check after the upload completes.
    /// Intervals shorter than 10 ms count as 10 ms.
    public var initialInterval: TimeInterval
    /// Upper bound for the (growing) interval between checks.
    public var maxInterval: TimeInterval
    /// Growth factor applied after every check that is still `processing`.
    /// One below 1 counts as 1: the interval never shrinks.
    public var multiplier: Double
    /// How long to wait for the job once its inputs are uploaded. Only the
    /// waits between checks count, never time the app spent suspended or the
    /// device asleep. When it runs out the job is checked once more, and a
    /// job still running is kept: the conversion throws `.jobTimedOut`,
    /// which `isResumable`.
    public var jobTimeout: TimeInterval
    /// Consecutive transient poll failures tolerated before giving up. Each
    /// "failure" is itself a `GET /jobs/{id}` that already exhausted
    /// `apiRetryPolicy`, so the default tolerates minutes of API trouble.
    public var maxConsecutiveFailures: Int

    public init(initialInterval: TimeInterval = 1.0,
                maxInterval: TimeInterval = 6.0,
                multiplier: Double = 1.5,
                jobTimeout: TimeInterval = 30 * 60,
                maxConsecutiveFailures: Int = 5) {
        self.initialInterval = initialInterval
        self.maxInterval = maxInterval
        self.multiplier = multiplier
        self.jobTimeout = jobTimeout
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    public static let `default` = PollingPolicy()
}

/// Weights used to fold the three network phases into one 0…1 progress value.
public struct ProgressWeights: Equatable, Sendable {
    public var upload: Double
    public var processing: Double
    public var download: Double

    public init(upload: Double = 0.45, processing: Double = 0.35, download: Double = 0.20) {
        self.upload = upload
        self.processing = processing
        self.download = download
    }

    public static let `default` = ProgressWeights()
}

public struct CloudConvertConfiguration: Sendable {

    // MARK: Endpoint & auth

    public var environment: CloudConvertEnvironment
    /// Supplies the `Authorization` header for API requests (API key when
    /// talking to CloudConvert directly, your own token when using a proxy).
    public var authorizationProvider: any AuthorizationProvider

    // MARK: Retry / resilience

    /// Retries for JSON API calls (create job, poll, delete…).
    public var apiRetryPolicy: RetryPolicy
    /// Retries for a single upload HTTP request against the same upload form.
    public var uploadRetryPolicy: RetryPolicy
    /// Retries for downloading an exported file.
    public var downloadRetryPolicy: RetryPolicy
    /// Retries at the *job* level: how many times a failed job is rebuilt from
    /// scratch (new job, new upload) when the failure is classified retryable.
    public var jobRetryPolicy: RetryPolicy
    public var polling: PollingPolicy
    /// How long the engine waits for connectivity to return before giving up:
    /// with `.notConnected` before the job exists, and after that with
    /// `.timedOut(phase: .waitingForNetwork)`, which `isResumable`. Progress
    /// reports `.waitingForNetwork` meanwhile.
    public var offlineWaitTimeout: TimeInterval
    /// Timeout for a single API request (not transfers).
    public var apiRequestTimeout: TimeInterval
    /// Resource timeout for uploads/downloads (background sessions can be long).
    public var transferResourceTimeout: TimeInterval
    /// Server-side task timeout in seconds sent as the `timeout` option on
    /// processing tasks. Keeps a stuck conversion from holding a job for hours.
    public var serverTaskTimeout: Int?

    // MARK: Limits

    /// Local cap on input size; the upload form also carries `max_file_size`
    /// and the smaller of the two is enforced.
    public var maxInputFileSize: Int64
    /// Maximum number of conversions the queue runs simultaneously.
    public var maxConcurrentConversions: Int
    /// Extra free space to require beyond the expected output size.
    public var diskSpaceSafetyMargin: Int64

    // MARK: Files

    /// Directory for staged inputs, multipart bodies and in-flight downloads.
    public var workingDirectory: URL
    /// Default directory for finished outputs (can be overridden per request).
    public var outputDirectory: URL
    /// Identifier for the background `URLSession`. Must be unique per app and
    /// stable across launches.
    public var backgroundSessionIdentifier: String
    /// Set to `false` to use a standard (foreground) session for transfers.
    public var usesBackgroundTransfers: Bool
    /// Allow uploads and downloads over cellular. `false` restricts transfers
    /// to Wi-Fi; the (tiny) API calls are always allowed.
    public var allowsCellularTransfers: Bool

    // MARK: Misc

    public var progressWeights: ProgressWeights
    public var logger: any CloudConvertLogging
    /// Lets the app grant the pipeline extra execution time after it is
    /// backgrounded (UIKit's `beginBackgroundTask`) without the kit importing
    /// UIKit. See `BackgroundActivityProviding` for the ten-line adapter.
    public var backgroundActivity: any BackgroundActivityProviding
    /// Free-form `tag` sent with every job (e.g. app name + version) to make
    /// jobs identifiable in the CloudConvert dashboard.
    public var jobTag: String?

    public init(environment: CloudConvertEnvironment,
                authorizationProvider: any AuthorizationProvider,
                backgroundSessionIdentifier: String,
                workingDirectory: URL? = nil,
                outputDirectory: URL? = nil,
                logger: any CloudConvertLogging = OSLogCloudConvertLogger(),
                jobTag: String? = nil) {
        self.environment = environment
        self.authorizationProvider = authorizationProvider
        self.backgroundSessionIdentifier = backgroundSessionIdentifier
        self.logger = logger
        self.jobTag = jobTag

        self.apiRetryPolicy = .api
        self.uploadRetryPolicy = .upload
        self.downloadRetryPolicy = .download
        self.jobRetryPolicy = .job
        self.polling = .default
        self.offlineWaitTimeout = 90
        self.apiRequestTimeout = 30
        self.transferResourceTimeout = 6 * 60 * 60
        self.serverTaskTimeout = 25 * 60

        self.maxInputFileSize = 2 * 1024 * 1024 * 1024 // 2 GB
        self.maxConcurrentConversions = 2
        self.diskSpaceSafetyMargin = 100 * 1024 * 1024

        let root = CloudConvertConfiguration.defaultRootDirectory
        self.workingDirectory = workingDirectory ?? root.appendingPathComponent("Work", isDirectory: true)
        self.outputDirectory = outputDirectory ?? root.appendingPathComponent("Converted", isDirectory: true)

        self.usesBackgroundTransfers = true
        self.allowsCellularTransfers = true
        self.progressWeights = .default
        self.backgroundActivity = NoBackgroundActivity()
    }

    /// `Application Support/<bundle id>/CloudConvertKit/`.
    ///
    /// Application Support is used on every platform so the kit never writes
    /// into a user-visible location: on iOS it is inside the app container
    /// like Documents, and on macOS (sandboxed or not) it is the app-private
    /// area under `~/Library`, whereas `~/Documents` would be the user's real
    /// Documents folder. The bundle-identifier segment keeps unsandboxed Mac
    /// apps apart, since they all share the same `~/Library/Application Support`.
    /// The directory is created on first use (`FileStorage.prepareDirectories`).
    public static var defaultRootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "CloudConvertKit"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("CloudConvertKit", isDirectory: true)
    }
}

// MARK: - Convenience factories

public extension CloudConvertConfiguration {

    /// Talk to your own backend which holds the CloudConvert API key.
    static func proxy(baseURL: URL,
                      authorization: any AuthorizationProvider = NoAuthorization(),
                      backgroundSessionIdentifier: String,
                      jobTag: String? = nil) -> CloudConvertConfiguration {
        CloudConvertConfiguration(environment: .proxy(baseURL: baseURL),
                                  authorizationProvider: authorization,
                                  backgroundSessionIdentifier: backgroundSessionIdentifier,
                                  jobTag: jobTag)
    }

    /// Talk to CloudConvert directly with an API key (development / sandbox).
    ///
    /// - Important: `environment` defaults to **`.sandbox`**, not `.production`.
    ///   A production API key used against the sandbox is rejected with 401
    ///   (`CloudConvertError.unauthorized`). Always pass `environment:`
    ///   explicitly; the default will be removed in the next major version.
    static func direct(apiKey: String,
                       environment: CloudConvertEnvironment = .sandbox,
                       backgroundSessionIdentifier: String,
                       jobTag: String? = nil) -> CloudConvertConfiguration {
        CloudConvertConfiguration(environment: environment,
                                  authorizationProvider: StaticAPIKeyAuthorization(apiKey: apiKey),
                                  backgroundSessionIdentifier: backgroundSessionIdentifier,
                                  jobTag: jobTag)
    }
}

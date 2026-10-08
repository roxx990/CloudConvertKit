//  Exponential backoff with full jitter, plus the single `retrying` helper
//  every layer uses so retry behaviour is identical everywhere.
//

import Foundation

public struct RetryPolicy: Equatable, Sendable {
    /// Total attempts including the first one. `1` means no retries.
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var multiplier: Double
    /// 0 → deterministic delays, 1 → full jitter (delay in `0…computed`).
    public var jitter: Double

    public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, multiplier: Double = 2.0, jitter: Double = 0.5) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.jitter = min(max(jitter, 0), 1)
    }

    public static let api = RetryPolicy(maxAttempts: 5, baseDelay: 0.8, maxDelay: 20)
    public static let upload = RetryPolicy(maxAttempts: 3, baseDelay: 2, maxDelay: 30)
    public static let download = RetryPolicy(maxAttempts: 4, baseDelay: 1.5, maxDelay: 30)
    public static let job = RetryPolicy(maxAttempts: 2, baseDelay: 3, maxDelay: 30)
    /// A single attempt, no retries (best-effort calls such as job deletion).
    public static let disabled = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)

    /// Delay before retry number `attempt` (1-based: the delay *after* the
    /// first failure is `delay(forAttempt: 1)`).
    public func delay(forAttempt attempt: Int, randomSource: (Double, Double) -> Double = { Double.random(in: $0...$1) }) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let raw = min(maxDelay, baseDelay * pow(multiplier, exponent))
        guard jitter > 0, raw > 0 else { return raw }
        let low = raw * (1 - jitter)
        return randomSource(low, raw)
    }

    public func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt < maxAttempts
    }
}

/// Runs `operation` until it succeeds, the policy is exhausted, the error is
/// not retryable, or the task is cancelled.
///
/// - `classify` decides how a failure is treated. It defaults to the
///   `CloudConvertError` rules, and is exposed so callers can add context.
/// - Connectivity failures do **not** consume attempts; instead `waitForNetwork`
///   is awaited (the engine passes `ConnectivityMonitor.waitUntilConnected`).
/// - A 429 with `Retry-After` overrides the computed delay.
/// - `isSafeToRepeat`, when given, must also approve every repeat. Requests
///   that are not idempotent (`POST /jobs`) pass one that only allows errors
///   proving the server never processed the request.
func retrying<T>(policy: RetryPolicy,
                 phase: ConversionPhase,
                 logger: any CloudConvertLogging,
                 label: String,
                 waitForNetwork: (@Sendable () async throws -> Void)? = nil,
                 isSafeToRepeat: (@Sendable (CloudConvertError) -> Bool)? = nil,
                 onRetry: (@Sendable (_ attempt: Int, _ delay: TimeInterval, _ error: CloudConvertError) async -> Void)? = nil,
                 operation: @Sendable () async throws -> T) async throws -> T {
    var attempt = 0
    var offlineWaits = 0

    while true {
        try Task.checkCancellation()
        do {
            return try await operation()
        } catch {
            let ccError = CloudConvertError.wrap(error, phase: phase)
            if case .cancelled = ccError { throw ccError }
            let safeToRepeat = isSafeToRepeat?(ccError) ?? true

            // Offline: wait for the network instead of burning attempts.
            if ccError.isConnectivityRelated, safeToRepeat, let waitForNetwork, offlineWaits < 3 {
                offlineWaits += 1
                logger.notice("\(label): offline (\(ccError.analyticsCode)); waiting for connectivity", metadata: ["phase": phase.rawValue])
                try await waitForNetwork()
                // The wait returns at once when the path is up but the host is
                // unreachable; back off instead of re-sending immediately.
                try await Task.sleep(seconds: policy.delay(forAttempt: offlineWaits))
                continue
            }

            attempt += 1
            guard ccError.isRetryable, safeToRepeat, policy.shouldRetry(afterAttempt: attempt) else {
                logger.error("\(label): giving up after \(attempt) attempt(s): \(ccError.analyticsCode)", metadata: ["phase": phase.rawValue])
                throw ccError
            }

            let delay = ccError.mandatoryRetryDelay.map { max($0, 0.5) } ?? policy.delay(forAttempt: attempt)
            logger.warning("\(label): attempt \(attempt) failed (\(ccError.analyticsCode)); retrying in \(String(format: "%.1f", delay))s",
                           metadata: ["phase": phase.rawValue])
            await onRetry?(attempt, delay, ccError)
            try await Task.sleep(seconds: delay)
        }
    }
}

extension Task where Success == Never, Failure == Never {
    /// `Task.sleep(nanoseconds:)` for any delay, including one that came from
    /// a server: a negative or NaN delay does not sleep, and a huge or
    /// infinite one is capped instead of trapping in `UInt64(_:)`.
    static func sleep(seconds: TimeInterval) async throws {
        try await sleep(nanoseconds: seconds > 0 ? UInt64(min(seconds, 1e9) * 1e9) : 0)
    }
}

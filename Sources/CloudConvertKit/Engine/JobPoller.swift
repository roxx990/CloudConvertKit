//  Polls `GET /jobs/{id}` until the job reaches a terminal status. Interval
//  grows geometrically to keep request volume (and rate-limit pressure) low
//  on long conversions, transient failures are tolerated up to a budget, and
//  going offline pauses polling instead of failing.
//

import Foundation

struct JobPoller: Sendable {

    let api: any CloudConvertAPIClient
    let policy: PollingPolicy
    let connectivity: any ConnectivityMonitoring
    let offlineWaitTimeout: TimeInterval
    let logger: any CloudConvertLogging

    /// Returns the job in its terminal state (`finished` or `error`).
    ///
    /// `policy.jobTimeout` counts the waits between checks as planned, not
    /// wall-clock time: a wait that overran because the app was suspended or
    /// the device asleep counts only as long as it was meant to last. And
    /// the job is always checked once more when the deadline has passed, so
    /// a job that finished meanwhile is never given up on.
    func waitForCompletion(jobID: String,
                           onUpdate: @Sendable (CCJob) async -> Void) async throws -> CCJob {
        // The waits must add up to `jobTimeout`, so none is shorter than
        // `minimumInterval`, and the multiplier never shortens them.
        let initialInterval = Double.maximum(policy.initialInterval, Self.minimumInterval)
        let maxInterval = Double.maximum(policy.maxInterval, Self.minimumInterval)
        let multiplier = Double.maximum(policy.multiplier, 1)
        var interval = initialInterval
        var consecutiveFailures = 0
        var waited: TimeInterval = 0

        while true {
            try Task.checkCancellation()
            var rateLimitWait: TimeInterval?

            do {
                let job = try await api.getJob(id: jobID)
                consecutiveFailures = 0
                await onUpdate(job)

                if job.status.isTerminal {
                    return job
                }
            } catch let error as CloudConvertError {
                switch error {
                case .cancelled:
                    throw error
                case .notFound:
                    throw CloudConvertError.jobLost(jobID: jobID)
                case .unauthorized, .forbidden, .paymentRequired, .validation:
                    throw error
                case .rateLimited(let retryAfter):
                    // Not a failure of the job; just slow down.
                    let wait = Double.maximum(retryAfter ?? maxInterval, initialInterval)
                    logger.notice("Job \(jobID): rate limited while polling; waiting \(String(format: "%.0f", wait))s")
                    rateLimitWait = wait
                default:
                    if error.isConnectivityRelated {
                        // Falls through to the normal sleep: when the network
                        // path is up but the host is unreachable (captive
                        // portal, proxy down) the wait returns at once, and
                        // `continue` would poll in a tight loop. When the
                        // network stays away the wait throws `.notConnected`,
                        // and the engine keeps the conversion to resume later.
                        logger.notice("Job \(jobID): offline while polling; waiting for connectivity")
                        try await connectivity.waitUntilConnected(timeout: offlineWaitTimeout)
                    } else {
                        consecutiveFailures += 1
                        logger.warning("Job \(jobID): poll failed (\(consecutiveFailures)/\(policy.maxConsecutiveFailures)): \(error.analyticsCode)")
                        if consecutiveFailures >= policy.maxConsecutiveFailures {
                            throw error
                        }
                    }
                }
            } catch {
                throw CloudConvertError.wrap(error, phase: .processing)
            }

            guard waited < policy.jobTimeout else {
                logger.error("Job \(jobID) exceeded the polling deadline")
                throw CloudConvertError.jobTimedOut(jobID: jobID)
            }
            let wait = min(rateLimitWait ?? interval, policy.jobTimeout - waited)
            try await Task.sleep(seconds: wait)
            waited += wait
            if rateLimitWait == nil {
                interval = min(maxInterval, interval * multiplier)
            }
        }
    }

    /// The shortest wait between two checks of a job.
    static let minimumInterval: TimeInterval = 0.01
}

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
    func waitForCompletion(jobID: String,
                           deadline: Date,
                           onUpdate: @Sendable (CCJob) async -> Void) async throws -> CCJob {
        var interval = policy.initialInterval
        var consecutiveFailures = 0

        while true {
            try Task.checkCancellation()

            if Date() >= deadline {
                logger.error("Job \(jobID) exceeded the polling deadline")
                throw CloudConvertError.jobTimedOut(jobID: jobID)
            }

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
                    let wait = max(retryAfter ?? policy.maxInterval, policy.initialInterval)
                    logger.notice("Job \(jobID): rate limited while polling; waiting \(Int(wait))s")
                    try await sleep(wait, deadline: deadline)
                    continue
                default:
                    if error.isConnectivityRelated {
                        logger.notice("Job \(jobID): offline while polling; waiting for connectivity")
                        try await connectivity.waitUntilConnected(timeout: offlineWaitTimeout)
                        continue
                    }
                    consecutiveFailures += 1
                    logger.warning("Job \(jobID): poll failed (\(consecutiveFailures)/\(policy.maxConsecutiveFailures)): \(error.analyticsCode)")
                    if consecutiveFailures >= policy.maxConsecutiveFailures {
                        throw error
                    }
                }
            } catch {
                throw CloudConvertError.wrap(error, phase: .processing)
            }

            try await sleep(interval, deadline: deadline)
            interval = min(policy.maxInterval, interval * policy.multiplier)
        }
    }

    private func sleep(_ seconds: TimeInterval, deadline: Date) async throws {
        let clamped = max(0, min(seconds, deadline.timeIntervalSinceNow))
        guard clamped > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }
}

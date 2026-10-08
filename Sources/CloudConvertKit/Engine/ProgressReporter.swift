//  Folds per-phase progress into a single monotonic 0…1 value and fans it out
//  to the caller's handler. Thread-safe because transfer callbacks arrive on
//  URLSession's delegate queue.
//

import Foundation

public typealias ConversionProgressHandler = @Sendable (ConversionProgress) -> Void

final class ProgressReporter: @unchecked Sendable {

    private let lock = NSLock()
    private let conversionID: String
    private let weights: ProgressWeights
    private let handler: ConversionProgressHandler?
    private var current: ConversionProgress
    private var highWaterMark: Double = 0
    /// Set by the terminal stage. Late transfer callbacks (URLSession delivers
    /// progress on its own queue) must not report `.uploading` after `.cancelled`.
    private var isFinished = false

    // Upload bookkeeping: bytes per upload task.
    private var uploadTotals: [String: Int64] = [:]
    private var uploadCompleted: [String: Int64] = [:]
    // Download bookkeeping: bytes per file index.
    private var downloadTotals: [Int: Int64] = [:]
    private var downloadCompleted: [Int: Int64] = [:]

    init(conversionID: String, weights: ProgressWeights, handler: ConversionProgressHandler?) {
        self.conversionID = conversionID
        self.weights = weights
        self.handler = handler
        self.current = ConversionProgress(conversionID: conversionID, stage: .preparing, fractionCompleted: 0)
    }

    var latest: ConversionProgress {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    // MARK: Stage transitions

    func stage(_ stage: ConversionProgress.Stage, jobAttempt: Int? = nil, jobID: String? = nil) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        if stage.isTerminal { isFinished = true }
        current.stage = stage
        if let jobAttempt { current.jobAttempt = jobAttempt }
        if let jobID { current.jobID = jobID }
        switch stage {
        case .completed:
            current.fractionCompleted = 1
        case .preparing, .creatingJob:
            current.bytesTransferred = nil
            current.bytesTotal = nil
        default:
            break
        }
        deliverLocked()
    }

    /// A rebuilt job starts its transfers over; progress must not run backwards
    /// within an attempt, but a new attempt legitimately restarts.
    func resetForNewAttempt(_ attempt: Int) {
        lock.lock()
        uploadTotals.removeAll(); uploadCompleted.removeAll()
        downloadTotals.removeAll(); downloadCompleted.removeAll()
        highWaterMark = 0
        current.fractionCompleted = 0
        current.jobAttempt = attempt
        current.jobID = nil
        lock.unlock()
    }

    // MARK: Uploads

    func registerUpload(taskName: String, totalBytes: Int64) {
        lock.lock()
        uploadTotals[taskName] = max(1, totalBytes)
        uploadCompleted[taskName] = 0
        lock.unlock()
    }

    func upload(taskName: String, progress: TransferProgress) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        if progress.totalBytes > 0 { uploadTotals[taskName] = progress.totalBytes }
        uploadCompleted[taskName] = progress.completedBytes
        let total = uploadTotals.values.reduce(0, +)
        let done = uploadCompleted.values.reduce(0, +)
        let fraction = total > 0 ? Double(done) / Double(total) : 0
        current.stage = .uploading
        current.bytesTransferred = done
        current.bytesTotal = total
        setFractionLocked(weights.upload * fraction)
        deliverLocked()
    }

    func uploadFinished(taskName: String) {
        lock.lock()
        uploadCompleted[taskName] = uploadTotals[taskName]
        lock.unlock()
    }

    // MARK: Processing

    /// `fraction` is 0…1 within the processing phase.
    func processing(fraction: Double, jobID: String?) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        current.stage = .processing
        current.bytesTransferred = nil
        current.bytesTotal = nil
        if let jobID { current.jobID = jobID }
        setFractionLocked(weights.upload + weights.processing * min(0.98, max(0, fraction)))
        deliverLocked()
    }

    // MARK: Downloads

    func registerDownload(index: Int, totalBytes: Int64?) {
        lock.lock()
        downloadTotals[index] = max(1, totalBytes ?? 1)
        downloadCompleted[index] = 0
        lock.unlock()
    }

    func download(index: Int, progress: TransferProgress) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        if progress.totalBytes > 0 { downloadTotals[index] = progress.totalBytes }
        downloadCompleted[index] = progress.completedBytes
        // Totals start from the sizes the server reported.
        let total = downloadTotals.values.saturatingSum()
        let done = downloadCompleted.values.saturatingSum()
        let fraction = total > 0 ? Double(done) / Double(total) : 0
        current.stage = .downloading
        current.bytesTransferred = done
        current.bytesTotal = total
        setFractionLocked(weights.upload + weights.processing + weights.download * fraction)
        deliverLocked()
    }

    func downloadFinished(index: Int) {
        lock.lock()
        downloadCompleted[index] = downloadTotals[index]
        lock.unlock()
    }

    // MARK: Helpers

    /// Calls the handler while still holding the lock, so updates reach the
    /// handler in the order they were made and none arrives after the
    /// terminal stage. Unlocks.
    private func deliverLocked() {
        let snapshot = current
        handler?(snapshot)
        lock.unlock()
    }

    private func setFractionLocked(_ value: Double) {
        highWaterMark = max(highWaterMark, min(1, max(0, value)))
        current.fractionCompleted = highWaterMark
    }
}

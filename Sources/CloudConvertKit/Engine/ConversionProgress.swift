//  Progress and result types delivered to the caller. The kit never touches
//  UI: handlers are invoked on arbitrary threads and the app decides how to
//  hop to the main actor (see `ConversionViewModel` in CloudConvertKitUI).
//

import Foundation

/// What a `.retrying` stage refers to.
public enum RetryScope: Equatable, Sendable {
    /// One HTTP-level phase (an upload or download request) is being retried
    /// against the same job.
    case phase(ConversionPhase)
    /// The whole job is being rebuilt (new job, new upload form, re-upload).
    case job
}

public struct ConversionProgress: Equatable, Sendable {

    public enum Stage: Equatable, Sendable {
        case preparing
        case waitingForNetwork
        case creatingJob
        case uploading
        case processing
        case downloading
        case finishing
        /// Waiting `delay` seconds before retry number `attempt` after `reason`
        /// (an `analyticsCode`). `scope` says whether a single phase or the
        /// whole job is being retried.
        case retrying(attempt: Int, delay: TimeInterval, scope: RetryScope, reason: String)
        case completed
        case failed
        case cancelled

        public var phase: ConversionPhase? {
            switch self {
            case .preparing: return .preparing
            case .waitingForNetwork: return .waitingForNetwork
            case .creatingJob: return .creatingJob
            case .uploading: return .uploading
            case .processing: return .processing
            case .downloading: return .downloading
            case .finishing: return .finishing
            case .retrying(_, _, let scope, _):
                if case .phase(let phase) = scope { return phase }
                return nil
            case .completed, .failed, .cancelled: return nil
            }
        }

        public var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    public var conversionID: String
    public var stage: Stage
    /// 0…1 across the whole pipeline (upload + processing + download).
    public var fractionCompleted: Double
    /// Bytes for the current transfer, when known.
    public var bytesTransferred: Int64?
    public var bytesTotal: Int64?
    /// Job-level attempt (1-based). Increments when a job is rebuilt.
    public var jobAttempt: Int
    /// Server job id once created (useful for support tickets).
    public var jobID: String?

    public init(conversionID: String,
                stage: Stage,
                fractionCompleted: Double,
                bytesTransferred: Int64? = nil,
                bytesTotal: Int64? = nil,
                jobAttempt: Int = 1,
                jobID: String? = nil) {
        self.conversionID = conversionID
        self.stage = stage
        self.fractionCompleted = min(1, max(0, fractionCompleted))
        self.bytesTransferred = bytesTransferred
        self.bytesTotal = bytesTotal
        self.jobAttempt = jobAttempt
        self.jobID = jobID
    }

    /// Short, user-presentable description of the current stage. Apps that
    /// localise should switch on `stage` themselves; this is English only.
    public var localizedStageDescription: String {
        switch stage {
        case .preparing: return "Preparing…"
        case .waitingForNetwork: return "Waiting for network…"
        case .creatingJob: return "Starting…"
        case .uploading: return "Uploading…"
        case .processing: return "Converting…"
        case .downloading: return "Downloading…"
        case .finishing: return "Finishing…"
        case .retrying(let attempt, _, _, _): return "Retrying (\(attempt))…"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// One produced file.
public struct ConvertedFile: Equatable, Sendable, Codable {
    public var url: URL
    public var filename: String
    public var size: Int64

    public init(url: URL, filename: String, size: Int64) {
        self.url = url
        self.filename = filename
        self.size = size
    }
}

public struct ConversionResult: Equatable, Sendable, Codable {
    public var conversionID: String
    public var jobID: String
    public var files: [ConvertedFile]
    /// Credits the job consumed, when reported.
    public var credits: Int?
    public var duration: TimeInterval
    public var userInfo: [String: String]

    public var primaryFile: ConvertedFile? { files.first }

    public init(conversionID: String, jobID: String, files: [ConvertedFile], credits: Int?, duration: TimeInterval, userInfo: [String: String]) {
        self.conversionID = conversionID
        self.jobID = jobID
        self.files = files
        self.credits = credits
        self.duration = duration
        self.userInfo = userInfo
    }
}

/// Estimates processing progress when the server does not report a percent.
/// Uses a saturating curve on elapsed time so the bar keeps moving but never
/// reaches the end before the job actually finishes.
public enum ProcessingProgressEstimator {
    /// `expectedDuration` is the time after which the estimate reaches ~63%.
    public static func estimate(elapsed: TimeInterval, expectedDuration: TimeInterval) -> Double {
        guard expectedDuration > 0 else { return 0 }
        return 1 - exp(-elapsed / expectedDuration)
    }

    /// Rough expectation from the input size and output type.
    public static func expectedDuration(inputBytes: Int64, outputFormat: String?) -> TimeInterval {
        let megabytes = Double(inputBytes) / 1_048_576
        let videoFormats: Set<String> = ["mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv", "3gp", "gif"]
        let isVideo = outputFormat.map { videoFormats.contains($0.lowercased()) } ?? false
        let perMegabyte = isVideo ? 2.0 : 0.4
        return max(6, min(600, 8 + megabytes * perMegabyte))
    }
}

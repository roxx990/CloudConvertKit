//  One error type for the whole pipeline. Every failure that can reach the
//  app is normalised into this enum so callers only have to reason about one
//  taxonomy: is it retryable, should we wait for the network, and what do we
//  tell the user.
//

import Foundation

/// Server-side task failure codes CloudConvert is known to return in
/// `task.code`. Unknown codes are preserved verbatim in `.other`.
public enum TaskFailureCode: Equatable, Sendable {
    case inputTaskFailed        // an upstream task (usually import) failed
    case conversionFailed       // the engine could not convert the file
    case invalidConversionType  // this input → output pair is not supported
    case sandboxFileNotAllowed  // sandbox API: file not whitelisted
    case timeout                // task exceeded its `timeout`
    case cancelled
    case downloadFailed         // import/url could not fetch the file
    case uploadFailed           // export target rejected the upload
    case openFailed             // engine could not open (corrupt / password protected)
    case fileTooLarge
    case insufficientCredits
    case other(String)

    public init(rawCode: String?) {
        switch rawCode?.uppercased() {
        case "INPUT_TASK_FAILED": self = .inputTaskFailed
        case "CONVERSION_FAILED": self = .conversionFailed
        case "INVALID_CONVERSION_TYPE": self = .invalidConversionType
        case "SANDBOX_FILE_NOT_ALLOWED": self = .sandboxFileNotAllowed
        case "TIMEOUT", "TIMED_OUT": self = .timeout
        case "CANCELLED", "CANCELED": self = .cancelled
        case "DOWNLOAD_FAILED": self = .downloadFailed
        case "UPLOAD_FAILED": self = .uploadFailed
        case "OPEN_FAILED": self = .openFailed
        case "FILE_TOO_LARGE", "FILE_SIZE_EXCEEDED": self = .fileTooLarge
        case "INSUFFICIENT_CREDITS", "PAYMENT_REQUIRED": self = .insufficientCredits
        case .some(let code): self = .other(code)
        case .none: self = .other("UNKNOWN")
        }
    }

    /// Whether re-running the whole job (fresh upload) has a realistic chance
    /// of succeeding. Deterministic failures (unsupported conversion, corrupt
    /// file) are not retried; they would only burn credits.
    public var isRetryable: Bool {
        switch self {
        case .timeout, .other, .inputTaskFailed, .downloadFailed, .uploadFailed:
            return true
        case .conversionFailed, .invalidConversionType, .sandboxFileNotAllowed,
             .cancelled, .openFailed, .fileTooLarge, .insufficientCredits:
            return false
        }
    }
}

/// The phase of the pipeline in which a failure occurred. Useful for
/// analytics: "80% of failures are in `.upload`" is actionable.
public enum ConversionPhase: String, Codable, Sendable {
    case preparing
    case waitingForNetwork
    case creatingJob
    case uploading
    case processing
    case downloading
    case finishing
}

/// Body of a CloudConvert API error response:
/// `{"message": "...", "code": "...", "errors": {"field": ["..."]}}`.
///
/// Decoded leniently: `errors` is flattened from whatever shape the server
/// (or a proxy) sends, so a surprising payload never hides the message.
public struct APIErrorPayload: Codable, Equatable, Sendable {
    public var message: String?
    public var code: String?
    public var errors: [String: [String]]?

    public init(message: String? = nil, code: String? = nil, errors: [String: [String]]? = nil) {
        self.message = message
        self.code = code
        self.errors = errors
    }

    enum CodingKeys: String, CodingKey { case message, code, errors }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        code = try? container.decodeIfPresent(String.self, forKey: .code)
        if let object = try? container.decodeIfPresent([String: JSONValue].self, forKey: .errors) {
            errors = object.mapValues(APIErrorPayload.strings(from:))
        } else if let list = try? container.decodeIfPresent([JSONValue].self, forKey: .errors) {
            errors = ["errors": list.flatMap(APIErrorPayload.strings(from:))]
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .errors) {
            errors = ["errors": [text]]
        } else {
            errors = nil
        }
    }

    private static func strings(from value: JSONValue) -> [String] {
        switch value {
        case .string(let text): return [text]
        case .int(let number): return [String(number)]
        case .double(let number): return [String(number)]
        case .bool(let flag): return [String(flag)]
        case .null: return []
        case .array(let items): return items.flatMap(strings(from:))
        case .object(let object): return object.sorted { $0.key < $1.key }.flatMap { strings(from: $0.value) }
        }
    }

    /// Flattens the validation dictionary into a single readable string.
    public var flattenedErrors: String? {
        guard let errors, !errors.isEmpty else { return nil }
        return errors
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.joined(separator: ", "))" }
            .joined(separator: "; ")
    }
}

public enum CloudConvertError: Error, Sendable {

    // Local / pre-flight
    case fileNotFound(URL)
    case fileNotReadable(URL, underlying: String?)
    case emptyFile(URL)
    case fileTooLarge(URL, size: Int64, limit: Int64)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case invalidRequest(reason: String)
    case storage(reason: String)

    // Connectivity
    case notConnected
    case network(code: URLError.Code, description: String)
    case timedOut(phase: ConversionPhase)
    case cancelled

    // HTTP layer (API + proxy)
    case unauthorized(APIErrorPayload?)
    case paymentRequired(APIErrorPayload?)
    case forbidden(APIErrorPayload?)
    case notFound(APIErrorPayload?)
    case validation(APIErrorPayload?)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int, APIErrorPayload?)
    case unexpectedStatus(status: Int, body: String?)
    case invalidResponse(reason: String)
    case decoding(reason: String)

    // Upload / download
    case uploadFormInvalid
    case uploadFormExpired
    case uploadRejected(status: Int, body: String?)
    case exportMissing(jobID: String)
    case downloadFailed(url: URL, status: Int?, description: String?)
    /// A background transfer we were waiting on no longer exists (the system
    /// dropped it, or the app was reinstalled). The phase is restarted.
    case transferLost(id: String)

    // Job / task level
    case jobFailed(jobID: String, taskName: String?, code: TaskFailureCode, message: String?)
    case jobLost(jobID: String)          // job disappeared server-side (24h purge / deleted)
    case jobTimedOut(jobID: String)      // exceeded the configured overall deadline

    // Catch-all after all retries were exhausted; carries the last error.
    case retriesExhausted(attempts: Int, last: String)
}

// MARK: - Classification

public extension CloudConvertError {

    /// True when a retry — after the suggested delay — might succeed.
    var isRetryable: Bool {
        switch self {
        case .notConnected, .network, .timedOut, .rateLimited, .serverError,
             .uploadFormExpired, .downloadFailed, .jobLost, .transferLost:
            return true
        case .uploadRejected(let status, _):
            return status >= 500 || status == 408 || status == 429
        case .unexpectedStatus(let status, _):
            return status >= 500 || status == 408 || status == 429
        case .jobFailed(_, _, let code, _):
            return code.isRetryable
        case .invalidResponse, .decoding:
            // Usually a transient proxy/CDN hiccup returning HTML; worth one more try.
            return true
        case .fileNotFound, .fileNotReadable, .emptyFile, .fileTooLarge, .insufficientDiskSpace,
             .invalidRequest, .storage, .cancelled, .unauthorized, .paymentRequired, .forbidden,
             .notFound, .validation, .uploadFormInvalid, .exportMissing, .jobTimedOut, .retriesExhausted:
            return false
        }
    }

    /// True for `.cancelled`: the user (or the app) stopped the conversion.
    /// UIs should show nothing, or a neutral "Cancelled" state, not an error.
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    /// True when the failure was caused by the device being offline. The engine
    /// waits for connectivity instead of counting these against the retry budget.
    var isConnectivityRelated: Bool {
        switch self {
        case .notConnected:
            return true
        case .network(let code, _):
            return CloudConvertError.connectivityURLErrorCodes.contains(code)
        default:
            return false
        }
    }

    /// A server-imposed wait (429 `Retry-After`) that must be honoured before retrying.
    var mandatoryRetryDelay: TimeInterval? {
        if case .rateLimited(let retryAfter) = self { return retryAfter }
        return nil
    }

    /// True when the *upload form* must be recreated (i.e. the whole job must be
    /// rebuilt) rather than retrying the same HTTP request.
    var requiresNewJob: Bool {
        switch self {
        case .uploadFormExpired, .uploadRejected, .jobLost, .transferLost:
            return true
        case .jobFailed(_, _, let code, _):
            return code.isRetryable
        default:
            return false
        }
    }

    static let connectivityURLErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .internationalRoamingOff,
        .dataNotAllowed,
        .callIsActive,
        .timedOut,
        .secureConnectionFailed,
    ]
}

// MARK: - Mapping from arbitrary errors

public extension CloudConvertError {

    /// Normalises any thrown error into a `CloudConvertError`.
    static func wrap(_ error: Error, phase: ConversionPhase) -> CloudConvertError {
        if let error = error as? CloudConvertError { return error }
        if error is CancellationError { return .cancelled }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut(phase: phase)
            case .notConnectedToInternet: return .notConnected
            default: return .network(code: code, description: nsError.localizedDescription)
            }
        }
        if let decodingError = error as? DecodingError {
            return .decoding(reason: String(describing: decodingError))
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                if let url = nsError.userInfo[NSURLErrorKey] as? URL { return .fileNotFound(url) }
                return .storage(reason: nsError.localizedDescription)
            case NSFileWriteOutOfSpaceError:
                return .insufficientDiskSpace(required: 0, available: 0)
            default:
                return .storage(reason: nsError.localizedDescription)
            }
        }
        return .invalidResponse(reason: nsError.localizedDescription)
    }
}

// MARK: - User-facing text

extension CloudConvertError: LocalizedError {

    public var errorDescription: String? { userFacingMessage }

    /// A short message safe to show in an alert. Never leaks URLs, tokens or
    /// raw server payloads.
    public var userFacingMessage: String {
        switch self {
        case .fileNotFound:
            return "The file could not be found. It may have been moved or deleted."
        case .fileNotReadable:
            return "The file could not be read. Please pick it again."
        case .emptyFile:
            return "The file is empty and cannot be converted."
        case .fileTooLarge(_, let size, let limit):
            return "This file is too large (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))). The limit is \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))."
        case .insufficientDiskSpace:
            return "There is not enough free space on this device to save the converted file."
        case .invalidRequest(let reason):
            return "This conversion could not be started: \(reason)"
        case .storage:
            return "The converted file could not be saved on this device."
        case .notConnected:
            return "You appear to be offline. Check your connection and try again."
        case .network:
            return "A network error interrupted the conversion. Please try again."
        case .timedOut:
            return "The connection timed out. Please try again."
        case .cancelled:
            return "The conversion was cancelled."
        case .unauthorized, .forbidden:
            return "The conversion service refused the request. Please update the app or try again later."
        case .paymentRequired:
            return "The conversion service is temporarily unavailable. Please try again later."
        case .notFound:
            return "The conversion could not be found on the server. Please start again."
        case .validation(let payload):
            if let detail = payload?.flattenedErrors ?? payload?.message {
                return "The conversion request was rejected: \(detail)"
            }
            return "The conversion request was rejected. This file type or option is not supported."
        case .rateLimited:
            return "Too many conversions were started at once. Please wait a moment and try again."
        case .serverError, .unexpectedStatus, .invalidResponse, .decoding:
            return "The conversion service is having trouble right now. Please try again in a moment."
        case .uploadFormInvalid, .uploadFormExpired:
            return "The upload could not be started. Please try again."
        case .uploadRejected:
            return "The file could not be uploaded. Please try again."
        case .exportMissing:
            return "The conversion finished but no output file was produced."
        case .downloadFailed:
            return "The converted file could not be downloaded. Please try again."
        case .transferLost:
            return "The transfer was interrupted. Please try again."
        case .jobFailed(_, _, let code, let message):
            switch code {
            case .invalidConversionType:
                return "Converting between these two formats is not supported."
            case .openFailed:
                return "The file could not be opened. It may be corrupted or password protected."
            case .fileTooLarge:
                return "This file is too large to convert."
            case .timeout:
                return "The conversion took too long and was stopped. Try a smaller file."
            case .sandboxFileNotAllowed:
                return "This file is not allowed in the sandbox environment."
            case .insufficientCredits:
                return "The conversion service is temporarily unavailable. Please try again later."
            case .cancelled:
                return "The conversion was cancelled."
            default:
                if let message, !message.isEmpty { return "Conversion failed: \(message)" }
                return "The conversion failed. Please try again or use a different file."
            }
        case .jobLost:
            return "The conversion expired on the server. Please start again."
        case .jobTimedOut:
            return "The conversion took too long and was stopped. Please try again."
        case .retriesExhausted:
            return "The conversion failed after several attempts. Please try again later."
        }
    }

    /// A stable identifier for analytics / crash reporting dashboards.
    public var analyticsCode: String {
        switch self {
        case .fileNotFound: return "file_not_found"
        case .fileNotReadable: return "file_not_readable"
        case .emptyFile: return "empty_file"
        case .fileTooLarge: return "file_too_large"
        case .insufficientDiskSpace: return "insufficient_disk_space"
        case .invalidRequest: return "invalid_request"
        case .storage: return "storage"
        case .notConnected: return "not_connected"
        case .network(let code, _): return "network_\(code.rawValue)"
        case .timedOut(let phase): return "timed_out_\(phase.rawValue)"
        case .cancelled: return "cancelled"
        case .unauthorized: return "http_401"
        case .paymentRequired: return "http_402"
        case .forbidden: return "http_403"
        case .notFound: return "http_404"
        case .validation: return "http_422"
        case .rateLimited: return "http_429"
        case .serverError(let status, _): return "http_\(status)"
        case .unexpectedStatus(let status, _): return "http_unexpected_\(status)"
        case .invalidResponse: return "invalid_response"
        case .decoding: return "decoding"
        case .uploadFormInvalid: return "upload_form_invalid"
        case .uploadFormExpired: return "upload_form_expired"
        case .uploadRejected(let status, _): return "upload_rejected_\(status)"
        case .exportMissing: return "export_missing"
        case .downloadFailed: return "download_failed"
        case .transferLost: return "transfer_lost"
        case .jobFailed(_, _, let code, _):
            if case .other(let raw) = code { return "job_failed_\(raw.lowercased())" }
            return "job_failed_\(String(describing: code))"
        case .jobLost: return "job_lost"
        case .jobTimedOut: return "job_timed_out"
        case .retriesExhausted: return "retries_exhausted"
        }
    }
}

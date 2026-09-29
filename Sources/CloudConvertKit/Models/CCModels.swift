//  Codable mirrors of the CloudConvert v2 REST resources. Prefixed `CC` to
//  avoid clashing with Swift's `Task`.
//

import Foundation

// MARK: - Envelope

/// Every successful API response wraps its payload in `data`.
public struct CCDataEnvelope<Payload: Decodable>: Decodable {
    public let data: Payload
}

// MARK: - Status

public enum CCStatus: String, Codable, Equatable, Sendable {
    case waiting
    case processing
    case finished
    case error

    /// Unknown future statuses decode as `.processing` so the poller keeps
    /// going instead of crashing on a new value.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CCStatus(rawValue: raw.lowercased()) ?? .processing
    }

    public var isTerminal: Bool { self == .finished || self == .error }
}

// MARK: - Job

public struct CCJob: Decodable, Equatable, Sendable {
    public let id: String
    public let tag: String?
    public let status: CCStatus
    public let createdAt: Date?
    public let startedAt: Date?
    public let endedAt: Date?
    public let tasks: [CCTask]

    enum CodingKeys: String, CodingKey {
        case id, tag, status, tasks
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
        status = try container.decodeIfPresent(CCStatus.self, forKey: .status) ?? .processing
        // Timestamps are informational; an odd one must not fail the job.
        createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
        startedAt = try? container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try? container.decodeIfPresent(Date.self, forKey: .endedAt)
        tasks = try container.decodeIfPresent([CCTask].self, forKey: .tasks) ?? []
    }

    public func task(named name: String) -> CCTask? {
        tasks.first { $0.name == name }
    }

    public func tasks(withOperation operation: String) -> [CCTask] {
        tasks.filter { $0.operation == operation }
    }

    /// The first task that reports an error, preferring the root cause over
    /// tasks that merely failed because their input failed.
    public var failedTask: CCTask? {
        let failed = tasks.filter { $0.status == .error }
        return failed.first { TaskFailureCode(rawCode: $0.code) != .inputTaskFailed } ?? failed.first
    }
}

// MARK: - Task

public struct CCTask: Decodable, Equatable, Sendable {
    public let id: String
    public let jobID: String?
    public let name: String?
    public let operation: String
    public let status: CCStatus
    public let message: String?
    public let code: String?
    public let credits: Int?
    public let percent: Double?
    public let createdAt: Date?
    public let startedAt: Date?
    public let endedAt: Date?
    public let engine: String?
    public let engineVersion: String?
    public let retryOfTaskID: String?
    public let result: CCTaskResult?

    enum CodingKeys: String, CodingKey {
        case id, name, operation, status, message, code, credits, percent, engine, result
        case jobID = "job_id"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case engineVersion = "engine_version"
        case retryOfTaskID = "retry_of_task_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        operation = try container.decodeIfPresent(String.self, forKey: .operation) ?? ""
        status = try container.decodeIfPresent(CCStatus.self, forKey: .status) ?? .processing
        message = try container.decodeIfPresent(String.self, forKey: .message)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        credits = CCLenient.int(container, .credits)
        // `percent` is not consistently present; tolerate number or string.
        if let value = try? container.decodeIfPresent(Double.self, forKey: .percent) {
            percent = value
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .percent) {
            percent = Double(text)
        } else {
            percent = nil
        }
        createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
        startedAt = try? container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try? container.decodeIfPresent(Date.self, forKey: .endedAt)
        engine = try? container.decodeIfPresent(String.self, forKey: .engine)
        engineVersion = try? container.decodeIfPresent(String.self, forKey: .engineVersion)
        retryOfTaskID = try container.decodeIfPresent(String.self, forKey: .retryOfTaskID)
        // An empty result may be serialised as `[]` instead of `{}` or `null`.
        result = try? container.decodeIfPresent(CCTaskResult.self, forKey: .result)
    }

    public var failureCode: TaskFailureCode? {
        status == .error ? TaskFailureCode(task: self) : nil
    }
}

/// `result` differs per operation: `import/upload` returns a `form`,
/// `export/url` returns `files`, `metadata` returns `metadata`.
///
/// Decoded leniently: one task's odd `result` must never make the whole job
/// undecodable, because the engine only reads the upload forms and the export
/// task's files. A field that does not decode is `nil` instead.
public struct CCTaskResult: Decodable, Equatable, Sendable {
    public let form: CCUploadForm?
    /// Files that can be downloaded, i.e. entries that carry a `url`.
    ///
    /// Only `export/url` tasks list files with URLs. Other tasks (`convert`,
    /// a finished `import/upload`, …) list theirs by `filename` and `size`
    /// alone; those entries are left out rather than failing the decode.
    public let files: [CCExportedFile]?
    public let metadata: [String: JSONValue]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        form = try? container.decodeIfPresent(CCUploadForm.self, forKey: .form)
        files = (try? container.decodeIfPresent([LossyExportedFile].self, forKey: .files))?.compactMap(\.file)
        metadata = try? container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
    }

    enum CodingKeys: String, CodingKey { case form, files, metadata }

    /// Decodes one `files` entry, or `nil` when it has no usable `url`.
    private struct LossyExportedFile: Decodable {
        let file: CCExportedFile?
        init(from decoder: Decoder) throws { file = try? CCExportedFile(from: decoder) }
    }
}

/// Upload target for `import/upload`. Parameters are opaque and must be sent
/// back verbatim, in order, with the file as the last multipart field.
public struct CCUploadForm: Decodable, Equatable, Sendable {
    public let url: URL
    /// Preserves the server's key order, which the upload endpoint expects.
    public let parameters: [(key: String, value: String)]

    enum CodingKeys: String, CodingKey { case url, parameters }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        let ordered = try container.decode(OrderedStringDictionary.self, forKey: .parameters)
        parameters = ordered.pairs
    }

    public init(url: URL, parameters: [(key: String, value: String)]) {
        self.url = url
        self.parameters = parameters
    }

    public static func == (lhs: CCUploadForm, rhs: CCUploadForm) -> Bool {
        lhs.url == rhs.url &&
        lhs.parameters.map(\.key) == rhs.parameters.map(\.key) &&
        lhs.parameters.map(\.value) == rhs.parameters.map(\.value)
    }

    public func parameter(_ key: String) -> String? {
        parameters.first { $0.key == key }?.value
    }

    /// `max_file_size` in bytes, when the server sent it.
    public var maxFileSize: Int64? {
        parameter("max_file_size").flatMap { Int64($0) }
    }

    /// `expires` as a date, when the server sent it (UNIX seconds or ISO-8601).
    public var expiresAt: Date? {
        guard let raw = parameter("expires") else { return nil }
        if let seconds = TimeInterval(raw) { return Date(timeIntervalSince1970: seconds) }
        return ISO8601DateFormatter().date(from: raw)
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        // Keep a small margin so we never start an upload that expires mid-flight.
        return expiresAt.timeIntervalSinceNow < 30
    }
}

public struct CCExportedFile: Decodable, Equatable, Sendable {
    public let filename: String
    public let size: Int64?
    public let url: URL

    enum CodingKeys: String, CodingKey { case filename, size, url }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? "output"
        if let value = try? container.decodeIfPresent(Int64.self, forKey: .size) {
            size = value
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .size) {
            size = Int64(text)
        } else {
            size = nil
        }
        url = try container.decode(URL.self, forKey: .url)
    }

    public init(filename: String, size: Int64?, url: URL) {
        self.filename = filename
        self.size = size
        self.url = url
    }
}

// MARK: - Operations catalogue (GET /operations, GET /convert/formats)

/// One row of the operations catalogue. Decoded leniently: the catalogue is
/// large and its shape drifts (booleans as 0/1, engine versions as strings or
/// objects), and one odd row must not make the whole list undecodable.
public struct CCOperation: Decodable, Equatable, Sendable {
    public let operation: String
    public let inputFormat: String?
    public let outputFormat: String?
    public let engine: String?
    /// Engine versions offered for this pair, as returned by the API.
    public let engineVersions: [JSONValue]?
    public let credits: Int?
    public let deprecated: Bool?
    public let experimental: Bool?
    public let options: [CCOperationOption]?

    enum CodingKeys: String, CodingKey {
        case operation, engine, credits, deprecated, experimental, options
        case inputFormat = "input_format"
        case outputFormat = "output_format"
        case engineVersions = "engine_versions"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decodeIfPresent(String.self, forKey: .operation) ?? ""
        inputFormat = try? container.decodeIfPresent(String.self, forKey: .inputFormat)
        outputFormat = try? container.decodeIfPresent(String.self, forKey: .outputFormat)
        engine = try? container.decodeIfPresent(String.self, forKey: .engine)
        engineVersions = try? container.decodeIfPresent([JSONValue].self, forKey: .engineVersions)
        credits = CCLenient.int(container, .credits)
        deprecated = CCLenient.bool(container, .deprecated)
        experimental = CCLenient.bool(container, .experimental)
        options = try? container.decodeIfPresent([CCOperationOption].self, forKey: .options)
    }

    public init(operation: String, inputFormat: String?, outputFormat: String?, engine: String?,
                engineVersions: [JSONValue]? = nil, credits: Int? = nil, deprecated: Bool? = nil,
                experimental: Bool? = nil, options: [CCOperationOption]? = nil) {
        self.operation = operation
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.engine = engine
        self.engineVersions = engineVersions
        self.credits = credits
        self.deprecated = deprecated
        self.experimental = experimental
        self.options = options
    }
}

public struct CCOperationOption: Decodable, Equatable, Sendable {
    public let name: String
    public let type: String?
    public let `default`: JSONValue?
    public let possibleValues: [JSONValue]?
    public let description: String?

    enum CodingKeys: String, CodingKey {
        case name, type, description
        case `default`
        case possibleValues = "possible_values"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        `default` = try? container.decodeIfPresent(JSONValue.self, forKey: .default)
        possibleValues = try? container.decodeIfPresent([JSONValue].self, forKey: .possibleValues)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
    }
}

// MARK: - Account (GET /users/me)

public struct CCUser: Decodable, Equatable, Sendable {
    public let id: String
    public let username: String?
    public let email: String?
    /// Remaining conversion credits.
    public let credits: Int?
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, username, email, credits
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? container.decode(Int.self, forKey: .id) {
            id = String(number)
        } else {
            id = try container.decode(String.self, forKey: .id)
        }
        username = try? container.decodeIfPresent(String.self, forKey: .username)
        email = try? container.decodeIfPresent(String.self, forKey: .email)
        credits = CCLenient.int(container, .credits)
        createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

// MARK: - Pagination (GET /jobs, GET /tasks)

public struct CCPageMeta: Decodable, Equatable, Sendable {
    public let currentPage: Int?
    public let lastPage: Int?
    public let perPage: Int?
    public let total: Int?

    enum CodingKeys: String, CodingKey {
        case total
        case currentPage = "current_page"
        case lastPage = "last_page"
        case perPage = "per_page"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPage = CCLenient.int(container, .currentPage)
        lastPage = CCLenient.int(container, .lastPage)
        perPage = CCLenient.int(container, .perPage)
        total = CCLenient.int(container, .total)
    }

    public var hasMorePages: Bool {
        guard let currentPage, let lastPage else { return false }
        return currentPage < lastPage
    }
}

/// A page of a list endpoint: `{"data": [...], "meta": {...}}`.
public struct CCPage<Item: Decodable>: Decodable {
    public let data: [Item]
    public let meta: CCPageMeta?

    enum CodingKeys: String, CodingKey { case data, meta }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent([Item].self, forKey: .data) ?? []
        meta = try? container.decodeIfPresent(CCPageMeta.self, forKey: .meta)
    }

    init(data: [Item], meta: CCPageMeta?) {
        self.data = data
        self.meta = meta
    }
}

extension CCPage: Sendable where Item: Sendable {}
extension CCPage: Equatable where Item: Equatable {}

/// Tolerant scalar decoding for fields the API is not strict about.
enum CCLenient {
    static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Int(text) ?? Double(text).map { Int($0) } }
        return nil
    }

    static func bool<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Helpers

/// Decodes the upload-form `parameters` object into string pairs.
///
/// `JSONDecoder` does not guarantee key order, so a deterministic order is
/// applied instead: the keys CloudConvert documents first (in documented
/// order), any unknown keys alphabetically after them, and `signature` always
/// last. The upload endpoint validates the signature against the other fields,
/// and `file` is appended after all of them by the multipart writer.
struct OrderedStringDictionary: Decodable {
    let pairs: [(key: String, value: String)]

    private static let preferredOrder = ["expires", "max_file_count", "max_file_size"]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: JSONValue].self)

        var strings: [String: String] = [:]
        for (key, value) in raw {
            switch value {
            case .string(let s): strings[key] = s
            case .int(let i): strings[key] = String(i)
            case .double(let d): strings[key] = d.rounded() == d && abs(d) < 9e18 ? String(Int64(d)) : String(d)
            case .bool(let b): strings[key] = b ? "true" : "false"
            case .null, .array, .object: continue
            }
        }

        var ordered: [(key: String, value: String)] = []
        for key in Self.preferredOrder {
            if let value = strings.removeValue(forKey: key) { ordered.append((key, value)) }
        }
        let signature = strings.removeValue(forKey: "signature")
        for key in strings.keys.sorted() {
            ordered.append((key, strings[key]!))
        }
        if let signature { ordered.append(("signature", signature)) }
        pairs = ordered
    }
}

/// CloudConvert timestamps are ISO-8601 with fractional seconds and a `Z`.
public enum CCDateDecoding {

    /// `ISO8601DateFormatter` is documented as thread-safe; the box just
    /// states that to the compiler.
    private final class Parsers: @unchecked Sendable {
        let withFraction: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        let plain: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        func date(from text: String) -> Date? {
            if let date = withFraction.date(from: text) ?? plain.date(from: text) { return date }
            // Some proxies re-serialise dates with a space instead of `T`.
            let normalised = text.replacingOccurrences(of: " ", with: "T")
            return withFraction.date(from: normalised) ?? plain.date(from: normalised)
        }
    }

    private static let parsers = Parsers()

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let parsers = self.parsers
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = parsers.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(text)")
        }
        return decoder
    }
}

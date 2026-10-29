//  What CloudConvert converts, and with which options: `/convert/formats`
//  (with options) cached on disk, plus the options of the other operations,
//  so an app can offer only what works and a request is checked before its
//  upload spends credits.
//

import Foundation

/// An input → output format pair, by extension (`"doc"` → `"pdf"`).
public struct ConversionPair: Hashable, Sendable, Codable {
    public var input: String
    public var output: String

    public init(_ input: String, _ output: String) {
        self.input = input.lowercased()
        self.output = output.lowercased()
    }

    /// Pairs CloudConvert offers but fails on: DOC and PPT to PDF end in
    /// `EXPORT_FAILED` (the office engine's export), after the upload.
    public static let knownFailures: Set<ConversionPair> = [
        ConversionPair("doc", "pdf"),
        ConversionPair("ppt", "pdf"),
    ]
}

/// Something about a request the catalogue says will not work.
public enum CatalogIssue: Equatable, Sendable, CustomStringConvertible {
    /// CloudConvert does not convert `pair` (with `engine`, when one was asked for).
    case unsupportedConversion(ConversionPair, engine: String?)
    /// CloudConvert offers `pair` but is known to fail on it.
    case knownFailure(ConversionPair)
    /// `operation` takes no option `name` (with any engine that does it).
    case unknownOption(name: String, operation: String)
    /// `value` is not one of the values `name` accepts.
    case invalidValue(name: String, value: JSONValue, operation: String)

    public var description: String {
        switch self {
        case .unsupportedConversion(let pair, let engine):
            return "\(pair.input) → \(pair.output) is not supported" + (engine.map { " by \($0)" } ?? "")
        case .knownFailure(let pair):
            return "\(pair.input) → \(pair.output) is known to fail on CloudConvert"
        case .unknownOption(let name, let operation):
            return "\(operation) takes no option '\(name)'"
        case .invalidValue(let name, let value, let operation):
            return "\(operation): '\(name)' does not accept \(value)"
        }
    }
}

public actor CloudConvertCatalog {

    private let api: any CloudConvertAPIClient
    private let cacheURL: URL?
    private let maxAge: TimeInterval
    private let knownFailures: Set<ConversionPair>
    private let minimumInputFormats: Int
    private let logger: any CloudConvertLogging

    private var conversions: [CCOperation]?
    private var loadedAt: Date?
    private var loading: Task<[CCOperation], Error>?
    private var operationOptions: [String: [CCOperation]] = [:]

    /// - Parameters:
    ///   - cacheURL: Where the conversions list is kept between launches.
    ///   - maxAge: How long a list is used before it is fetched again.
    ///   - minimumInputFormats: A list with fewer input formats than this
    ///     is taken as cut short (a proxy or CDN hiccup): it is used, but
    ///     neither cached nor allowed to replace a longer one.
    public init(api: any CloudConvertAPIClient,
                cacheURL: URL? = nil,
                maxAge: TimeInterval = 7 * 24 * 60 * 60,
                knownFailures: Set<ConversionPair> = ConversionPair.knownFailures,
                minimumInputFormats: Int = 50,
                logger: any CloudConvertLogging = SilentCloudConvertLogger()) {
        self.api = api
        self.cacheURL = cacheURL
        self.maxAge = maxAge
        self.knownFailures = knownFailures
        self.minimumInputFormats = minimumInputFormats
        self.logger = logger
    }

    // MARK: Conversions

    /// Every `convert` row, with its options: from memory, the disk cache
    /// while it is fresh, or the API.
    public func allConversions() async throws -> [CCOperation] {
        if let conversions, let loadedAt, Date().timeIntervalSince(loadedAt) < maxAge { return conversions }
        if conversions == nil, let cached = readCache(), Date().timeIntervalSince(cached.savedAt) < maxAge {
            conversions = cached.operations
            loadedAt = cached.savedAt
            return cached.operations
        }
        if let loading { return try await loading.value }
        let api = self.api
        let task = Task { try await api.convertFormats(filter: OperationsFilter(includeOptions: true)) }
        loading = task
        defer { loading = nil }
        do {
            let fetched = try await task.value.filter { $0.operation == CCOperationName.convert.rawValue }
            accept(fetched)
            return conversions ?? fetched
        } catch {
            // A stale list beats none.
            if let conversions { return conversions }
            if let cached = readCache() {
                conversions = cached.operations
                loadedAt = cached.savedAt
                return cached.operations
            }
            throw error
        }
    }

    /// Whether CloudConvert converts `input` to `output` (with `engine`),
    /// leaving out pairs known to fail.
    public func supports(_ pair: ConversionPair, engine: String? = nil) async throws -> Bool {
        guard !knownFailures.contains(pair) else { return false }
        return try await rows(for: pair, engine: engine).isEmpty == false
    }

    /// The engines that convert `pair`.
    public func engines(for pair: ConversionPair) async throws -> [String] {
        try await rows(for: pair, engine: nil).compactMap(\.engine)
    }

    /// The options `pair` takes, with every engine or the one asked for.
    public func options(for pair: ConversionPair, engine: String? = nil) async throws -> [CCOperationOption] {
        Self.uniqueOptions(try await rows(for: pair, engine: engine))
    }

    /// The output formats `input` converts to, known failures left out.
    public func outputFormats(from input: String) async throws -> Set<String> {
        let input = input.lowercased()
        let outputs = try await allConversions()
            .filter { $0.inputFormat?.lowercased() == input }
            .compactMap { $0.outputFormat?.lowercased() }
        return Set(outputs).subtracting(knownFailures.filter { $0.input == input }.map(\.output))
    }

    // MARK: Other operations

    /// The options `operation` (`merge`, `optimize`, `archive`…) takes.
    public func options(forOperation operation: String, inputFormat: String? = nil) async throws -> [CCOperationOption] {
        let rows: [CCOperation]
        if let cached = operationOptions[operation] {
            rows = cached
        } else {
            rows = try await api.operations(filter: OperationsFilter(operation: operation, includeOptions: true))
            operationOptions[operation] = rows
        }
        let matching = inputFormat.map { format in rows.filter { $0.inputFormat == nil || $0.inputFormat?.lowercased() == format.lowercased() } } ?? rows
        return Self.uniqueOptions(matching)
    }

    // MARK: Checking a request

    /// What the catalogue says will fail in `request`: the pair and the
    /// options of every processing step. Options the kit itself sets
    /// (`input_format`, `filename`, `engine`…) are not checked.
    public func issues(in request: ConversionRequest) async throws -> [CatalogIssue] {
        var issues: [CatalogIssue] = []
        let inputFormats = Set(request.inputs.compactMap(\.effectiveInputFormat))
        for (index, step) in request.processingSteps.enumerated() {
            let options = index == 0 ? request.options.merging(step.options) { _, own in own } : step.options
            let engine = options["engine"]?.stringValue ?? (index == 0 ? request.engine : nil)
            switch step.operation {
            case .convert(let output):
                // Only the first step's inputs are known up front.
                guard index == 0 else { continue }
                for input in inputFormats.sorted() {
                    let pair = ConversionPair(input, output)
                    if knownFailures.contains(pair) { issues.append(.knownFailure(pair)); continue }
                    let rows = try await rows(for: pair, engine: engine)
                    guard !rows.isEmpty else { issues.append(.unsupportedConversion(pair, engine: engine)); continue }
                    // A pair listed without options (about a quarter are) can't be judged.
                    let accepted = Self.uniqueOptions(rows)
                    guard !accepted.isEmpty else { continue }
                    issues += Self.optionIssues(options, accepted: accepted, operation: "convert")
                }
            default:
                let name = step.operation.wireName
                let accepted = try await self.options(forOperation: name, inputFormat: index == 0 ? inputFormats.first : nil)
                // An operation listed without options can't be judged.
                guard !accepted.isEmpty else { continue }
                issues += Self.optionIssues(options, accepted: accepted, operation: name)
            }
        }
        return issues
    }

    // MARK: Internals

    private func rows(for pair: ConversionPair, engine: String?) async throws -> [CCOperation] {
        try await allConversions().filter {
            $0.inputFormat?.lowercased() == pair.input && $0.outputFormat?.lowercased() == pair.output
                && (engine == nil || $0.engine == engine)
        }
    }

    /// Options the kit sets on every task, whatever the catalogue lists.
    static let kitOptions: Set<String> = ["input_format", "output_format", "filename", "engine", "engine_version", "timeout"]

    static func optionIssues(_ options: [String: JSONValue], accepted: [CCOperationOption], operation: String) -> [CatalogIssue] {
        let byName = Dictionary(accepted.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var issues: [CatalogIssue] = []
        for (name, value) in options.sorted(by: { $0.key < $1.key }) where !kitOptions.contains(name) {
            guard let option = byName[name] else {
                issues.append(.unknownOption(name: name, operation: operation))
                continue
            }
            if let allowed = option.possibleValues, !allowed.isEmpty, value != .null,
               !allowed.contains(where: { Self.sameValue($0, value) }) {
                issues.append(.invalidValue(name: name, value: value, operation: operation))
            }
        }
        return issues
    }

    /// `"90"` and `90` are the same value to the API.
    static func sameValue(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if a == b { return true }
        func text(_ value: JSONValue) -> String? {
            switch value {
            case .string(let string): return string.lowercased()
            case .int(let number): return String(number)
            case .double(let number): return number == number.rounded() ? String(Int(number)) : String(number)
            case .bool(let flag): return String(flag)
            default: return nil
            }
        }
        return text(a) != nil && text(a) == text(b)
    }

    static func uniqueOptions(_ rows: [CCOperation]) -> [CCOperationOption] {
        var seen = Set<String>()
        return rows.flatMap { $0.options ?? [] }.filter { seen.insert($0.name).inserted }
    }

    private func accept(_ fetched: [CCOperation]) {
        let inputs = Set(fetched.compactMap(\.inputFormat)).count
        guard inputs >= minimumInputFormats else {
            logger.warning("Catalogue: only \(inputs) input formats; not cached")
            if conversions == nil {
                conversions = fetched
                loadedAt = Date()
            }
            return
        }
        conversions = fetched
        loadedAt = Date()
        writeCache(fetched)
    }

    private struct Cache: Codable {
        var savedAt: Date
        var body: Data
    }

    private func readCache() -> (operations: [CCOperation], savedAt: Date)? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              let envelope = try? CCDateDecoding.makeDecoder().decode(CCDataEnvelope<[CCOperation]>.self, from: cache.body) else { return nil }
        return (envelope.data, cache.savedAt)
    }

    private func writeCache(_ operations: [CCOperation]) {
        guard let cacheURL else { return }
        do {
            let body = try JSONEncoder().encode(["data": operations.map(\.wireObject)])
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Cache(savedAt: Date(), body: body)).write(to: cacheURL, options: .atomic)
        } catch {
            logger.warning("Catalogue: could not cache: \(error.localizedDescription)")
        }
    }
}

extension CCOperation {
    /// The row as the API sends it, for the disk cache.
    var wireObject: JSONValue {
        var object: [String: JSONValue] = ["operation": .string(operation)]
        if let inputFormat { object["input_format"] = .string(inputFormat) }
        if let outputFormat { object["output_format"] = .string(outputFormat) }
        if let engine { object["engine"] = .string(engine) }
        if let engineVersions { object["engine_versions"] = .array(engineVersions) }
        if let credits { object["credits"] = .int(credits) }
        if let deprecated { object["deprecated"] = .bool(deprecated) }
        if let experimental { object["experimental"] = .bool(experimental) }
        if let options { object["options"] = .array(options.map(\.wireObject)) }
        return .object(object)
    }
}

extension CCOperationOption {
    var wireObject: JSONValue {
        var object: [String: JSONValue] = ["name": .string(name)]
        if let type { object["type"] = .string(type) }
        if let value = `default` { object["default"] = value }
        if let possibleValues { object["possible_values"] = .array(possibleValues) }
        if let description { object["description"] = .string(description) }
        return .object(object)
    }
}

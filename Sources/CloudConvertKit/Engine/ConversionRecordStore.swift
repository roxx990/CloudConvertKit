//  Durable state for in-flight conversions so that a conversion started in a
//  previous launch can be resumed (or at least cleaned up) instead of leaving
//  the user with a spinner that never ends.
//

import Foundation

public struct ConversionRecord: Codable, Equatable, Sendable {
    public var id: String
    public var specification: JobSpecification
    /// Staged copies keyed by upload task name.
    public var staged: [String: StagedInput]
    public var output: OutputOptions
    public var userInfo: [String: String]
    public var createdAt: Date
    public var updatedAt: Date

    public var phase: ConversionPhase
    public var jobAttempt: Int
    public var jobID: String?
    /// Upload task name → transfer id (present once the upload was started).
    public var uploadTransfers: [String: String]
    /// Upload task names whose upload completed with 2xx.
    public var uploadedTaskNames: [String]
    /// Export file index → transfer id.
    public var downloadTransfers: [Int: String]
    /// Export files known once the job finished.
    public var exportedFiles: [ExportedFileRecord]
    /// `ConversionRequest.key` of the request that started it.
    public var key: String?
    /// Credits the job consumed, once it finished: kept for a resume that
    /// only has the downloads left.
    public var credits: Int?
    /// The record's format: nil for records written by CloudConvertKit 1.x.
    public var formatVersion: Int?

    static let currentFormatVersion = 2

    public var totalInputBytes: Int64 {
        staged.values.reduce(0) { $0 + $1.size }
    }

    /// The format of the files the job exports: the `output_format` of the
    /// task feeding the export, followed upstream through tasks that keep
    /// their input's format (`optimize`, `watermark`). Nil when that is the
    /// input's own format, or not known.
    public var outputFormatHint: String? {
        var name = specification.task(named: specification.exportTaskName)?.inputs.first
        var visited = Set<String>()
        while let current = name, visited.insert(current).inserted, let task = specification.task(named: current) {
            if task.isImport { return nil }
            if let format = task.options["output_format"]?.stringValue { return format }
            name = task.inputs.first
        }
        return nil
    }

    /// Whether the job can still be continued: CloudConvert purges jobs
    /// (and upload forms expire) long before a day passes.
    public func isExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) >= ConversionEngine.maxResumableAge
    }

    /// Whether a resume has what it needs: a job that has not expired, and
    /// the staged copies of its inputs. One that can't resume fails at once
    /// on `resumePendingConversions`, and starting it over is the way on.
    public var canResume: Bool {
        !isExpired() && staged.values.allSatisfy { FileManager.default.fileExists(atPath: $0.stagedURL.path) }
    }
}

/// A record on disk the store could not read (damaged, or written by a
/// release that changed the format): what is known of it, to clean up.
public struct UnreadableRecord: Equatable, Sendable {
    public var id: String
    public var jobID: String?

    public init(id: String, jobID: String?) {
        self.id = id
        self.jobID = jobID
    }
}

public struct ExportedFileRecord: Codable, Equatable, Sendable {
    public var filename: String
    public var size: Int64?
    public var url: URL
    /// Set once the file has been moved into the output directory.
    public var finalURL: URL?

    init(_ file: CCExportedFile) {
        filename = file.filename
        size = file.size
        url = file.url
    }
}

public protocol ConversionRecordStoring: Sendable {
    func save(_ record: ConversionRecord) async
    func load(id: String) async -> ConversionRecord?
    func delete(id: String) async
    func all() async -> [ConversionRecord]
    /// Removes the records that can no longer be read, returning what is
    /// known of each so the engine can delete its job and files.
    func removeUnreadableRecords() async -> [UnreadableRecord]
}

public extension ConversionRecordStoring {
    func removeUnreadableRecords() async -> [UnreadableRecord] { [] }
}

public actor ConversionRecordStore: ConversionRecordStoring {

    private let directory: URL
    private let logger: any CloudConvertLogging
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(directory: URL, logger: any CloudConvertLogging) {
        self.directory = directory
        self.logger = logger
    }

    public func save(_ record: ConversionRecord) {
        var record = record
        record.updatedAt = Date()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(record)
            try data.write(to: fileURL(for: record.id), options: .atomic)
        } catch {
            logger.warning("Could not persist conversion record \(record.id): \(error.localizedDescription)")
        }
    }

    public func load(id: String) -> ConversionRecord? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? decoder.decode(ConversionRecord.self, from: data)
    }

    public func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    public func all() -> [ConversionRecord] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ConversionRecord.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func removeUnreadableRecords() -> [UnreadableRecord] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var removed: [UnreadableRecord] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), (try? decoder.decode(ConversionRecord.self, from: data)) == nil else { continue }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let id = object?["id"] as? String ?? url.deletingPathExtension().lastPathComponent
            removed.append(UnreadableRecord(id: id, jobID: object?["jobID"] as? String))
            try? FileManager.default.removeItem(at: url)
            logger.warning("Removed unreadable conversion record \(id)")
        }
        return removed
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}

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

    public var totalInputBytes: Int64 {
        staged.values.reduce(0) { $0 + $1.size }
    }

    public var outputFormatHint: String? {
        specification.tasks
            .first { !$0.isImport && !$0.isExport }?
            .options["output_format"]?.stringValue
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

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}

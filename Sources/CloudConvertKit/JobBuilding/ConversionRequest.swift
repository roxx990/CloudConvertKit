//  The high-level request the apps actually use. It describes *what* the user
//  wants (these files → this format with these options) and is turned into a
//  `JobSpecification` by `makeJobSpecification`. Anything the request type
//  cannot express can be built with `JobBuilder` and run through
//  `ConversionEngine.run(_:output:)` directly.
//

import Foundation

/// The processing step applied to the input file(s).
public enum ProcessingOperation: Equatable, Sendable, Codable {
    /// One `convert` task per input; outputs are exported together.
    case convert(outputFormat: String)
    /// A single `merge` task combining all inputs into one file (PDF).
    case merge(outputFormat: String = "pdf")
    /// A single `archive` task packing all inputs into one archive.
    case archive(outputFormat: String = "zip")
    /// One `optimize` task per input (PDF / PNG / JPG compression).
    case optimize(profile: String? = nil)
    /// One `thumbnail` task per input.
    case thumbnail(outputFormat: String = "png", width: Int? = nil, height: Int? = nil, fit: String? = nil)
    /// One `watermark` task per input; text/image and placement go in `options`.
    case watermark
    /// One task per input with an arbitrary operation name (for new operations).
    case custom(operation: String, outputFormat: String?)

    /// The extension of the produced files, when it can be known up front.
    public var outputFormat: String? {
        switch self {
        case .convert(let format), .merge(let format), .archive(let format), .thumbnail(let format, _, _, _):
            return format.lowercased()
        case .custom(_, let format):
            return format?.lowercased()
        case .optimize, .watermark:
            return nil // same as the input
        }
    }

    /// Whether all inputs feed one task (`merge`, `archive`) or each input
    /// gets its own task.
    public var combinesInputs: Bool {
        switch self {
        case .merge, .archive: return true
        default: return false
        }
    }
}

public struct ExportOptions: Equatable, Sendable, Codable {
    /// Ask CloudConvert to zip multiple outputs into a single download.
    public var archiveMultipleFiles: Bool
    public var inline: Bool

    public init(archiveMultipleFiles: Bool = false, inline: Bool = false) {
        self.archiveMultipleFiles = archiveMultipleFiles
        self.inline = inline
    }

    public static let `default` = ExportOptions()
}

/// Where and how finished files are written.
public struct OutputOptions: Equatable, Sendable, Codable {
    /// Directory for the outputs. `nil` → `CloudConvertConfiguration.outputDirectory`.
    public var directory: URL?
    /// Preferred base name (without extension) for a single-output job. For
    /// multi-output jobs the server-provided filenames are used.
    public var preferredBaseName: String?
    /// Expected output size used for the free-space check. `nil` → estimate
    /// from the input size.
    public var expectedOutputBytes: Int64?

    public init(directory: URL? = nil, preferredBaseName: String? = nil, expectedOutputBytes: Int64? = nil) {
        self.directory = directory
        self.preferredBaseName = preferredBaseName
        self.expectedOutputBytes = expectedOutputBytes
    }

    public static let `default` = OutputOptions()
}

public struct ConversionRequest: Equatable, Sendable, Codable {

    public var inputs: [InputFile]
    public var operation: ProcessingOperation
    /// Engine options forwarded verbatim to each processing task
    /// (`audio_bitrate`, `quality`, `pages`, `video_codec`, …).
    public var options: [String: JSONValue]
    /// Output filename (with extension) for single-output operations.
    public var outputFilename: String?
    public var engine: String?
    public var engineVersion: String?
    /// Server-side `timeout` in seconds for the processing task(s).
    public var timeout: Int?
    public var export: ExportOptions
    public var output: OutputOptions
    /// Overrides the configuration's job tag.
    public var tag: String?
    /// Free-form client data echoed back on the result (e.g. a history row id).
    public var userInfo: [String: String]

    public init(inputs: [InputFile],
                operation: ProcessingOperation,
                options: [String: JSONValue] = [:],
                outputFilename: String? = nil,
                engine: String? = nil,
                engineVersion: String? = nil,
                timeout: Int? = nil,
                export: ExportOptions = .default,
                output: OutputOptions = .default,
                tag: String? = nil,
                userInfo: [String: String] = [:]) {
        self.inputs = inputs
        self.operation = operation
        self.options = options
        self.outputFilename = outputFilename
        self.engine = engine
        self.engineVersion = engineVersion
        self.timeout = timeout
        self.export = export
        self.output = output
        self.tag = tag
        self.userInfo = userInfo
    }

    // MARK: Convenience constructors

    /// `file.docx → pdf`
    public static func convert(_ url: URL,
                               to outputFormat: String,
                               options: [String: JSONValue] = [:],
                               inputFormat: String? = nil) -> ConversionRequest {
        ConversionRequest(inputs: [InputFile(url: url, inputFormat: inputFormat)],
                          operation: .convert(outputFormat: outputFormat),
                          options: options)
    }

    /// Several files, each converted to `outputFormat`, in one job.
    public static func convert(_ urls: [URL],
                               to outputFormat: String,
                               options: [String: JSONValue] = [:]) -> ConversionRequest {
        ConversionRequest(inputs: urls.map { InputFile(url: $0) },
                          operation: .convert(outputFormat: outputFormat),
                          options: options)
    }

    public static func merge(_ urls: [URL], outputFilename: String? = nil) -> ConversionRequest {
        ConversionRequest(inputs: urls.map { InputFile(url: $0) },
                          operation: .merge(),
                          outputFilename: outputFilename)
    }

    // MARK: Job specification

    public func makeJobSpecification(defaultTag: String?, defaultTimeout: Int?) throws -> JobSpecification {
        guard !inputs.isEmpty else {
            throw CloudConvertError.invalidRequest(reason: "No input files were provided.")
        }
        if operation.combinesInputs == false, inputs.count > 1, outputFilename != nil {
            throw CloudConvertError.invalidRequest(reason: "outputFilename can only be used with a single input or a combining operation.")
        }

        var builder = JobBuilder(tag: tag ?? defaultTag, defaultTimeout: timeout ?? defaultTimeout)

        var imports: [TaskRef] = []
        for (index, input) in inputs.enumerated() {
            imports.append(builder.importUpload(input, name: "import-\(index + 1)"))
        }

        var processing: [TaskRef] = []
        if operation.combinesInputs {
            processing.append(builder.addTask(name: "process-1",
                                              operation: operationName,
                                              inputs: imports,
                                              options: taskOptions(for: nil)))
        } else {
            for (index, importRef) in imports.enumerated() {
                processing.append(builder.addTask(name: "process-\(index + 1)",
                                                  operation: operationName,
                                                  inputs: [importRef],
                                                  options: taskOptions(for: inputs[index])))
            }
        }

        builder.exportURL(processing,
                          inline: export.inline,
                          archiveMultipleFiles: export.archiveMultipleFiles,
                          name: "export-1")
        return try builder.build()
    }

    private var operationName: String {
        switch operation {
        case .convert: return CCOperationName.convert.rawValue
        case .merge: return CCOperationName.merge.rawValue
        case .archive: return CCOperationName.archive.rawValue
        case .optimize: return CCOperationName.optimize.rawValue
        case .thumbnail: return CCOperationName.thumbnail.rawValue
        case .watermark: return CCOperationName.watermark.rawValue
        case .custom(let name, _): return name
        }
    }

    private func taskOptions(for input: InputFile?) -> [String: JSONValue] {
        var merged = options
        if let format = operation.outputFormat { merged["output_format"] = .string(format) }
        if let input, let inputFormat = input.effectiveInputFormat, merged["input_format"] == nil {
            merged["input_format"] = .string(inputFormat)
        }
        if case .optimize(let profile) = operation, let profile, merged["profile"] == nil {
            merged["profile"] = .string(profile)
        }
        if case .thumbnail(_, let width, let height, let fit) = operation {
            if let width, merged["width"] == nil { merged["width"] = .int(width) }
            if let height, merged["height"] == nil { merged["height"] = .int(height) }
            if let fit, merged["fit"] == nil { merged["fit"] = .string(fit) }
        }
        if let outputFilename, merged["filename"] == nil { merged["filename"] = .string(outputFilename) }
        if let engine, merged["engine"] == nil { merged["engine"] = .string(engine) }
        if let engineVersion, merged["engine_version"] == nil { merged["engine_version"] = .string(engineVersion) }
        return merged
    }
}

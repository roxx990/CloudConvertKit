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

    /// The operation's name on the wire (`convert`, `merge`, `optimize`…).
    public var wireName: String {
        switch self {
        case .convert: return CCOperationName.convert.rawValue
        case .merge: return CCOperationName.merge.rawValue
        case .archive: return CCOperationName.archive.rawValue
        case .optimize: return CCOperationName.optimize.rawValue
        case .thumbnail: return CCOperationName.thumbnail.rawValue
        case .watermark: return CCOperationName.watermark.rawValue
        case .custom(let name, _): return name
        }
    }
}

/// One more operation applied to what the step before it produced, in the
/// same job: `.convert(outputFormat: "pdf")` then `.optimize()`, or each
/// file converted and then `.archive()` into one ZIP. Nothing is
/// downloaded in between.
public struct ProcessingStep: Equatable, Sendable, Codable {
    public var operation: ProcessingOperation
    /// Engine options for this step's task(s) only.
    public var options: [String: JSONValue]

    public init(_ operation: ProcessingOperation, options: [String: JSONValue] = [:]) {
        self.operation = operation
        self.options = options
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
    /// Operations applied, in order, to what `operation` produced, in the
    /// same job. `options`, `engine` and `engineVersion` belong to
    /// `operation`; each step carries its own. `outputFilename` names what
    /// the last step produces.
    public var followUps: [ProcessingStep]
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
    /// Makes the request idempotent: with a key, `convert` continues the
    /// conversion kept for it (by a resumable error, or a previous launch)
    /// instead of converting, and billing, the file again, and starts over
    /// only when that one can no longer finish. Use the app's id for the
    /// item (a history row, a list entry). At most one conversion per key
    /// runs at a time.
    public var key: String?

    public init(inputs: [InputFile],
                operation: ProcessingOperation,
                followUps: [ProcessingStep] = [],
                options: [String: JSONValue] = [:],
                outputFilename: String? = nil,
                engine: String? = nil,
                engineVersion: String? = nil,
                timeout: Int? = nil,
                export: ExportOptions = .default,
                output: OutputOptions = .default,
                tag: String? = nil,
                userInfo: [String: String] = [:],
                key: String? = nil) {
        self.inputs = inputs
        self.operation = operation
        self.followUps = followUps
        self.key = key
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

    /// `operation` and then `followUps`, as steps.
    public var processingSteps: [ProcessingStep] {
        [ProcessingStep(operation)] + followUps
    }

    public func makeJobSpecification(defaultTag: String?, defaultTimeout: Int?) throws -> JobSpecification {
        guard !inputs.isEmpty else {
            throw CloudConvertError.invalidRequest(reason: "No input files were provided.")
        }
        let producesOneFile = inputs.count == 1 || processingSteps.contains { $0.operation.combinesInputs }
        if outputFilename != nil, !producesOneFile {
            throw CloudConvertError.invalidRequest(reason: "outputFilename can only be used with a single input or a combining operation.")
        }

        var builder = JobBuilder(tag: tag ?? defaultTag, defaultTimeout: timeout ?? defaultTimeout)

        var current: [TaskRef] = []
        // The format of what each current task produces, when known.
        var formats: [String?] = []
        for (index, input) in inputs.enumerated() {
            current.append(builder.importUpload(input, name: "import-\(index + 1)"))
            formats.append(input.effectiveInputFormat)
        }

        let steps = processingSteps
        for (stepIndex, step) in steps.enumerated() {
            let isFirst = stepIndex == 0
            let isLast = stepIndex == steps.count - 1
            // The first step keeps the 1.x task names (`process-1`…).
            let prefix = isFirst ? "process" : "step\(stepIndex + 1)"
            if step.operation.combinesInputs {
                let options = taskOptions(step, isFirst: isFirst, isLast: isLast, inputFormat: nil)
                current = [builder.addTask(name: "\(prefix)-1", operation: step.operation.wireName, inputs: current, options: options)]
                formats = [step.operation.outputFormat]
            } else {
                var next: [TaskRef] = []
                var nextFormats: [String?] = []
                for (index, ref) in current.enumerated() {
                    let options = taskOptions(step, isFirst: isFirst, isLast: isLast, inputFormat: formats[index])
                    next.append(builder.addTask(name: "\(prefix)-\(index + 1)", operation: step.operation.wireName,
                                                inputs: [ref], options: options))
                    nextFormats.append(step.operation.outputFormat ?? formats[index])
                }
                current = next
                formats = nextFormats
            }
        }

        builder.exportURL(current,
                          inline: export.inline,
                          archiveMultipleFiles: export.archiveMultipleFiles,
                          name: "export-1")
        return try builder.build()
    }

    private func taskOptions(_ step: ProcessingStep, isFirst: Bool, isLast: Bool, inputFormat: String?) -> [String: JSONValue] {
        var merged = isFirst ? options.merging(step.options) { _, own in own } : step.options
        if let format = step.operation.outputFormat { merged["output_format"] = .string(format) }
        // A combining task takes files of several formats: no single input format.
        if let inputFormat, merged["input_format"] == nil, !step.operation.combinesInputs {
            merged["input_format"] = .string(inputFormat)
        }
        if case .optimize(let profile) = step.operation, let profile, merged["profile"] == nil {
            merged["profile"] = .string(profile)
        }
        if case .thumbnail(_, let width, let height, let fit) = step.operation {
            if let width, merged["width"] == nil { merged["width"] = .int(width) }
            if let height, merged["height"] == nil { merged["height"] = .int(height) }
            if let fit, merged["fit"] == nil { merged["fit"] = .string(fit) }
        }
        if isLast, let outputFilename, merged["filename"] == nil { merged["filename"] = .string(outputFilename) }
        if isFirst {
            if let engine, merged["engine"] == nil { merged["engine"] = .string(engine) }
            if let engineVersion, merged["engine_version"] == nil { merged["engine_version"] = .string(engineVersion) }
        }
        return merged
    }
}

//  A small fluent builder for hand-crafted jobs. The typed helpers cover the
//  operations most apps need; `addTask` covers everything else.
//
//      var builder = JobBuilder(tag: "pdf-app")
//      let file = builder.importUpload(InputFile(url: url))
//      let pdf = builder.convert(file, to: "pdf", options: ["pages": "1-3"])
//      builder.exportURL(pdf)
//      let spec = try builder.build()
//

import Foundation

/// A reference to a task inside a `JobBuilder`.
public struct TaskRef: Equatable, Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

public struct JobBuilder: Sendable {

    public var tag: String?
    public var webhookURL: URL?
    /// Applied to every processing task that does not set its own `timeout`.
    public var defaultTimeout: Int?

    private var tasks: [TaskDefinition] = []
    private var uploads: [String: InputFile] = [:]
    private var exportName: String?
    private var counters: [String: Int] = [:]

    public init(tag: String? = nil, webhookURL: URL? = nil, defaultTimeout: Int? = nil) {
        self.tag = tag
        self.webhookURL = webhookURL
        self.defaultTimeout = defaultTimeout
    }

    // MARK: Generic

    @discardableResult
    public mutating func addTask(_ task: TaskDefinition) -> TaskRef {
        tasks.append(task)
        return TaskRef(task.name)
    }

    @discardableResult
    public mutating func addTask(name: String? = nil,
                                 operation: String,
                                 inputs: [TaskRef] = [],
                                 options: [String: JSONValue] = [:]) -> TaskRef {
        let resolvedName = name ?? nextName(for: operation)
        var options = options
        if let defaultTimeout, options["timeout"] == nil,
           !operation.hasPrefix("import/"), !operation.hasPrefix("export/") {
            options["timeout"] = .int(defaultTimeout)
        }
        return addTask(TaskDefinition(name: resolvedName,
                                      operation: operation,
                                      inputs: inputs.map(\.name),
                                      options: options))
    }

    // MARK: Imports

    @discardableResult
    public mutating func importUpload(_ file: InputFile, name: String? = nil) -> TaskRef {
        let ref = addTask(name: name, operation: CCOperationName.importUpload.rawValue)
        uploads[ref.name] = file
        return ref
    }

    @discardableResult
    public mutating func importURL(_ url: URL, filename: String, headers: [String: String] = [:], name: String? = nil) -> TaskRef {
        var options: [String: JSONValue] = ["url": .string(url.absoluteString), "filename": .string(filename)]
        if !headers.isEmpty {
            options["headers"] = .object(headers.mapValues(JSONValue.string))
        }
        return addTask(name: name, operation: CCOperationName.importURL.rawValue, options: options)
    }

    // MARK: Processing

    @discardableResult
    public mutating func convert(_ input: TaskRef,
                                 to outputFormat: String,
                                 inputFormat: String? = nil,
                                 filename: String? = nil,
                                 engine: String? = nil,
                                 engineVersion: String? = nil,
                                 options: [String: JSONValue] = [:],
                                 name: String? = nil) -> TaskRef {
        var merged = options
        merged["output_format"] = .string(outputFormat.lowercased())
        if let inputFormat { merged["input_format"] = .string(inputFormat.lowercased()) }
        if let filename { merged["filename"] = .string(filename) }
        if let engine { merged["engine"] = .string(engine) }
        if let engineVersion { merged["engine_version"] = .string(engineVersion) }
        return addTask(name: name, operation: CCOperationName.convert.rawValue, inputs: [input], options: merged)
    }

    @discardableResult
    public mutating func merge(_ inputs: [TaskRef],
                               outputFormat: String = "pdf",
                               filename: String? = nil,
                               options: [String: JSONValue] = [:],
                               name: String? = nil) -> TaskRef {
        var merged = options
        merged["output_format"] = .string(outputFormat.lowercased())
        if let filename { merged["filename"] = .string(filename) }
        return addTask(name: name, operation: CCOperationName.merge.rawValue, inputs: inputs, options: merged)
    }

    @discardableResult
    public mutating func archive(_ inputs: [TaskRef],
                                 outputFormat: String = "zip",
                                 filename: String? = nil,
                                 options: [String: JSONValue] = [:],
                                 name: String? = nil) -> TaskRef {
        var merged = options
        merged["output_format"] = .string(outputFormat.lowercased())
        if let filename { merged["filename"] = .string(filename) }
        return addTask(name: name, operation: CCOperationName.archive.rawValue, inputs: inputs, options: merged)
    }

    @discardableResult
    public mutating func optimize(_ input: TaskRef,
                                  inputFormat: String? = nil,
                                  profile: String? = nil,
                                  filename: String? = nil,
                                  options: [String: JSONValue] = [:],
                                  name: String? = nil) -> TaskRef {
        var merged = options
        if let inputFormat { merged["input_format"] = .string(inputFormat.lowercased()) }
        if let profile { merged["profile"] = .string(profile) }
        if let filename { merged["filename"] = .string(filename) }
        return addTask(name: name, operation: CCOperationName.optimize.rawValue, inputs: [input], options: merged)
    }

    @discardableResult
    public mutating func thumbnail(_ input: TaskRef,
                                   outputFormat: String = "png",
                                   width: Int? = nil,
                                   height: Int? = nil,
                                   fit: String? = nil,
                                   options: [String: JSONValue] = [:],
                                   name: String? = nil) -> TaskRef {
        var merged = options
        merged["output_format"] = .string(outputFormat.lowercased())
        if let width { merged["width"] = .int(width) }
        if let height { merged["height"] = .int(height) }
        if let fit { merged["fit"] = .string(fit) }
        return addTask(name: name, operation: CCOperationName.thumbnail.rawValue, inputs: [input], options: merged)
    }

    @discardableResult
    public mutating func watermark(_ input: TaskRef,
                                   options: [String: JSONValue],
                                   name: String? = nil) -> TaskRef {
        addTask(name: name, operation: CCOperationName.watermark.rawValue, inputs: [input], options: options)
    }

    @discardableResult
    public mutating func metadata(_ input: TaskRef, name: String? = nil) -> TaskRef {
        addTask(name: name, operation: CCOperationName.metadata.rawValue, inputs: [input])
    }

    // MARK: Export

    @discardableResult
    public mutating func exportURL(_ inputs: [TaskRef],
                                   inline: Bool = false,
                                   archiveMultipleFiles: Bool = false,
                                   name: String? = nil) -> TaskRef {
        var options: [String: JSONValue] = [:]
        if inline { options["inline"] = .bool(true) }
        if archiveMultipleFiles { options["archive_multiple_files"] = .bool(true) }
        let ref = addTask(name: name ?? "export", operation: CCOperationName.exportURL.rawValue, inputs: inputs, options: options)
        exportName = ref.name
        return ref
    }

    @discardableResult
    public mutating func exportURL(_ input: TaskRef,
                                   inline: Bool = false,
                                   archiveMultipleFiles: Bool = false,
                                   name: String? = nil) -> TaskRef {
        exportURL([input], inline: inline, archiveMultipleFiles: archiveMultipleFiles, name: name)
    }

    // MARK: Build

    public func build() throws -> JobSpecification {
        guard let exportName else {
            throw CloudConvertError.invalidRequest(reason: "The job has no export/url task; call exportURL(_:) last.")
        }
        let spec = JobSpecification(tasks: tasks, uploads: uploads, exportTaskName: exportName, tag: tag, webhookURL: webhookURL)
        try spec.validate()
        return spec
    }

    // MARK: Naming

    private mutating func nextName(for operation: String) -> String {
        let base = operation
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        let index = (counters[base] ?? 0) + 1
        counters[base] = index
        return "\(base)-\(index)"
    }
}

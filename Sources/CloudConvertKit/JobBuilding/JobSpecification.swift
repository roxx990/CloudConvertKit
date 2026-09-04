//  A fully described CloudConvert job: the ordered task graph plus the local
//  knowledge the engine needs (which local file feeds which import task, and
//  which task's output to download).
//

import Foundation

/// Well-known CloudConvert operations. `rawValue` is the wire name.
public enum CCOperationName: String, Codable, Sendable {
    case importUpload = "import/upload"
    case importURL = "import/url"
    case importBase64 = "import/base64"
    case importRaw = "import/raw"
    case exportURL = "export/url"
    case convert
    case merge
    case archive
    case optimize
    case thumbnail
    case watermark
    case metadata
    case captureWebsite = "capture-website"
    case command
}

/// One task inside a job, as sent on the wire.
public struct TaskDefinition: Equatable, Sendable, Codable {
    public var name: String
    public var operation: String
    /// Names of upstream tasks. Encoded as a string when there is exactly one,
    /// an array otherwise (both are accepted by the API for single inputs).
    public var inputs: [String]
    /// Every other parameter (`output_format`, `filename`, engine options…).
    public var options: [String: JSONValue]

    public init(name: String, operation: String, inputs: [String] = [], options: [String: JSONValue] = [:]) {
        self.name = name
        self.operation = operation
        self.inputs = inputs
        self.options = options
    }

    public init(name: String, operation: CCOperationName, inputs: [String] = [], options: [String: JSONValue] = [:]) {
        self.init(name: name, operation: operation.rawValue, inputs: inputs, options: options)
    }

    /// Wire representation (`{"operation": …, "input": …, …options}`).
    public var wireObject: [String: JSONValue] {
        var object = options
        object["operation"] = .string(operation)
        if inputs.count == 1 {
            object["input"] = .string(inputs[0])
        } else if inputs.count > 1 {
            object["input"] = .array(inputs.map(JSONValue.string))
        }
        return object
    }

    public var isImport: Bool { operation.hasPrefix("import/") }
    public var isExport: Bool { operation.hasPrefix("export/") }
    public var isUpload: Bool { operation == CCOperationName.importUpload.rawValue }

    /// Task names may only contain letters, digits, hyphens and underscores.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        } && name.count <= 64
    }
}

public struct JobSpecification: Equatable, Sendable, Codable {
    public var tasks: [TaskDefinition]
    public var tag: String?
    public var webhookURL: URL?
    /// Local files keyed by the `import/upload` task that will receive them.
    public var uploads: [String: InputFile]
    /// The `export/url` task whose files are downloaded when the job finishes.
    public var exportTaskName: String

    public init(tasks: [TaskDefinition],
                uploads: [String: InputFile],
                exportTaskName: String,
                tag: String? = nil,
                webhookURL: URL? = nil) {
        self.tasks = tasks
        self.uploads = uploads
        self.exportTaskName = exportTaskName
        self.tag = tag
        self.webhookURL = webhookURL
    }

    public var uploadTaskNames: [String] {
        tasks.filter(\.isUpload).map(\.name)
    }

    public var processingTaskNames: [String] {
        tasks.filter { !$0.isImport && !$0.isExport }.map(\.name)
    }

    public func task(named name: String) -> TaskDefinition? {
        tasks.first { $0.name == name }
    }

    /// Encodable body for `POST /jobs`.
    public var requestBody: [String: JSONValue] {
        var tasksObject: [String: JSONValue] = [:]
        for task in tasks {
            tasksObject[task.name] = .object(task.wireObject)
        }
        var body: [String: JSONValue] = ["tasks": .object(tasksObject)]
        if let tag { body["tag"] = .string(tag) }
        if let webhookURL { body["webhook_url"] = .string(webhookURL.absoluteString) }
        return body
    }

    /// Sanity checks performed before any network call so a malformed graph
    /// fails fast and locally.
    public func validate() throws {
        guard !tasks.isEmpty else {
            throw CloudConvertError.invalidRequest(reason: "A job needs at least one task.")
        }
        var seen = Set<String>()
        for task in tasks {
            guard TaskDefinition.isValidName(task.name) else {
                throw CloudConvertError.invalidRequest(reason: "Task name '\(task.name)' contains invalid characters.")
            }
            guard seen.insert(task.name).inserted else {
                throw CloudConvertError.invalidRequest(reason: "Duplicate task name '\(task.name)'.")
            }
        }
        for task in tasks {
            for input in task.inputs where !seen.contains(input) {
                throw CloudConvertError.invalidRequest(reason: "Task '\(task.name)' references unknown input '\(input)'.")
            }
            if task.isUpload, uploads[task.name] == nil {
                throw CloudConvertError.invalidRequest(reason: "Upload task '\(task.name)' has no local file bound to it.")
            }
        }
        guard let export = task(named: exportTaskName), export.isExport else {
            throw CloudConvertError.invalidRequest(reason: "Export task '\(exportTaskName)' is missing.")
        }
        guard !uploads.isEmpty || tasks.contains(where: \.isImport) else {
            throw CloudConvertError.invalidRequest(reason: "A job needs at least one import task.")
        }
    }
}

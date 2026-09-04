//  Local file plumbing: staging inputs, naming outputs, disk-space checks and
//  cleanup. Kept separate so the engine never touches FileManager directly.
//

import Foundation

public struct FileStorage: Sendable {

    public let workingDirectory: URL
    public let outputDirectory: URL
    private let safetyMargin: Int64

    public init(workingDirectory: URL, outputDirectory: URL, diskSpaceSafetyMargin: Int64) {
        self.workingDirectory = workingDirectory
        self.outputDirectory = outputDirectory
        self.safetyMargin = diskSpaceSafetyMargin
    }

    // MARK: Directories

    public var stagingDirectory: URL { workingDirectory.appendingPathComponent("staging", isDirectory: true) }
    public var bodiesDirectory: URL { workingDirectory.appendingPathComponent("bodies", isDirectory: true) }
    public var downloadsDirectory: URL { workingDirectory.appendingPathComponent("downloads", isDirectory: true) }
    public var recordsDirectory: URL { workingDirectory.appendingPathComponent("records", isDirectory: true) }

    public func prepareDirectories() throws {
        for directory in [stagingDirectory, bodiesDirectory, downloadsDirectory, recordsDirectory, outputDirectory] {
            try ensureDirectory(directory)
        }
        // Nothing here needs to be backed up to iCloud.
        var workingDirectory = self.workingDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? workingDirectory.setResourceValues(values)
    }

    public func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw CloudConvertError.storage(reason: "Could not create directory \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: Input validation & staging

    /// Validates the input and copies it into the staging directory so the
    /// pipeline owns a stable, non-security-scoped copy for its whole lifetime
    /// (document-picker URLs stop being readable once the picker's scope ends,
    /// and Photos exports live in temporary locations the system may purge).
    public func stage(_ input: InputFile, conversionID: String, limit: Int64) throws -> StagedInput {
        let source = input.url
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: source.path) else {
            throw CloudConvertError.fileNotFound(source)
        }
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw CloudConvertError.fileNotReadable(source, underlying: nil)
        }
        let size = try fileSize(at: source)
        guard size > 0 else { throw CloudConvertError.emptyFile(source) }
        guard size <= limit else { throw CloudConvertError.fileTooLarge(source, size: size, limit: limit) }

        try ensureDirectory(stagingDirectory.appendingPathComponent(conversionID, isDirectory: true))
        let filename = FileStorage.sanitizedFilename(input.filename ?? source.lastPathComponent)
        let destination = stagingDirectory
            .appendingPathComponent(conversionID, isDirectory: true)
            .appendingPathComponent(filename)

        try? FileManager.default.removeItem(at: destination)
        do {
            // Prefer a coordinated read for files from other apps' containers.
            var coordinatorError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { readURL in
                do { try FileManager.default.copyItem(at: readURL, to: destination) } catch { copyError = error }
            }
            if let coordinatorError { throw coordinatorError }
            if let copyError { throw copyError }
        } catch {
            throw CloudConvertError.fileNotReadable(source, underlying: error.localizedDescription)
        }

        return StagedInput(original: input, stagedURL: destination, filename: filename, size: size)
    }

    public func fileSize(at url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
            if let size = values.totalFileSize ?? values.fileSize { return Int64(size) }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw CloudConvertError.fileNotReadable(url, underlying: error.localizedDescription)
        }
    }

    // MARK: Disk space

    public func availableCapacity() -> Int64 {
        let values = try? outputDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    public func ensureDiskSpace(forExpectedBytes bytes: Int64) throws {
        let required = bytes + safetyMargin
        let available = availableCapacity()
        guard available >= required else {
            throw CloudConvertError.insufficientDiskSpace(required: required, available: available)
        }
    }

    // MARK: Outputs

    /// Moves a finished download into the output directory under a unique name.
    public func finalize(downloadedFile: URL, preferredName: String, into directory: URL? = nil) throws -> URL {
        let directory = directory ?? outputDirectory
        try ensureDirectory(directory)
        let destination = uniqueURL(in: directory, preferredName: FileStorage.sanitizedFilename(preferredName))
        do {
            try FileManager.default.moveItem(at: downloadedFile, to: destination)
        } catch {
            throw CloudConvertError.storage(reason: "Could not move output into place: \(error.localizedDescription)")
        }
        return destination
    }

    /// `name.ext` → `name (2).ext` → `name (3).ext`… until the path is free.
    public func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(preferredName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    // MARK: Cleanup

    /// Removes every temporary file belonging to a conversion.
    public func cleanup(conversionID: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: stagingDirectory.appendingPathComponent(conversionID, isDirectory: true))
        try? fm.removeItem(at: bodiesDirectory.appendingPathComponent(conversionID, isDirectory: true))
        try? fm.removeItem(at: downloadsDirectory.appendingPathComponent(conversionID, isDirectory: true))
    }

    /// Removes orphaned temporary files older than `age` (e.g. from crashes).
    public func purgeStaleTemporaryFiles(olderThan age: TimeInterval = 48 * 60 * 60) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        for directory in [stagingDirectory, bodiesDirectory, downloadsDirectory] {
            guard let items = try? fm.contentsOfDirectory(at: directory,
                                                          includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified < cutoff { try? fm.removeItem(at: item) }
            }
        }
    }

    // MARK: Naming helpers

    /// Strips characters that break multipart headers or file systems.
    public static func sanitizedFilename(_ name: String) -> String {
        var cleaned = name
            .components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix(".") { cleaned = "_" + cleaned.dropFirst() }
        if cleaned.isEmpty { cleaned = "file" }
        // Keep the total length reasonable for both S3 keys and APFS.
        if cleaned.count > 180 {
            let ext = (cleaned as NSString).pathExtension
            let base = String((cleaned as NSString).deletingPathExtension.prefix(160))
            cleaned = ext.isEmpty ? base : "\(base).\(ext)"
        }
        return cleaned
    }

    /// `report.docx` + `pdf` → `report.pdf`
    public static func outputName(for inputName: String, outputFormat: String) -> String {
        let base = (inputName as NSString).deletingPathExtension
        let ext = outputFormat.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ext.isEmpty ? base : "\(base).\(ext)"
    }
}

/// A local file to be uploaded.
public struct InputFile: Equatable, Hashable, Sendable, Codable {
    /// Local file URL. Security-scoped URLs are handled.
    public var url: URL
    /// Overrides the filename sent to CloudConvert (must include the extension).
    public var filename: String?
    /// Overrides format detection (`"jpg"`, `"docx"`, …). When nil, the
    /// extension of `filename ?? url` is used.
    public var inputFormat: String?

    public init(url: URL, filename: String? = nil, inputFormat: String? = nil) {
        self.url = url
        self.filename = filename
        self.inputFormat = inputFormat
    }

    public var effectiveFilename: String {
        FileStorage.sanitizedFilename(filename ?? url.lastPathComponent)
    }

    public var effectiveInputFormat: String? {
        if let inputFormat, !inputFormat.isEmpty { return inputFormat.lowercased() }
        let ext = (effectiveFilename as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}

public struct StagedInput: Equatable, Sendable, Codable {
    public var original: InputFile
    public var stagedURL: URL
    public var filename: String
    public var size: Int64
}

//  Writes a `multipart/form-data` body to disk, streaming the file part in
//  chunks. Two reasons this exists instead of building a `Data` in memory:
//  a 1.5 GB video would be jetsammed instantly, and background upload tasks
//  require a file-backed body anyway.
//

import Foundation

public struct MultipartFormBody: Sendable {
    public let fileURL: URL
    public let contentType: String
    public let contentLength: Int64
}

public enum MultipartFormWriter {

    private static let chunkSize = 1 << 20 // 1 MiB

    /// Builds the body for an `import/upload` form: every form parameter in
    /// order, then the file as the last field named `file`.
    /// `isCancelled` is polled between chunks so a cancelled conversion stops
    /// copying immediately (the writer usually runs on a plain dispatch queue
    /// where `Task.checkCancellation()` has nothing to check).
    public static func writeUploadBody(form: CCUploadForm,
                                       file: URL,
                                       filename: String,
                                       mimeType: String = "application/octet-stream",
                                       to destination: URL,
                                       isCancelled: () -> Bool = { false }) throws -> MultipartFormBody {
        let boundary = "----CloudConvertKit-" + UUID().uuidString
        let fields = form.parameters.map { ($0.key, $0.value) }
        return try write(fields: fields,
                         fileField: "file",
                         file: file,
                         filename: filename,
                         mimeType: mimeType,
                         boundary: boundary,
                         to: destination,
                         isCancelled: isCancelled)
    }

    public static func write(fields: [(String, String)],
                             fileField: String,
                             file: URL,
                             filename: String,
                             mimeType: String,
                             boundary: String,
                             to destination: URL,
                             isCancelled: () -> Bool = { false }) throws -> MultipartFormBody {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CloudConvertError.storage(reason: "Could not create multipart body file.")
        }

        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destination)
        } catch {
            throw CloudConvertError.storage(reason: "Could not open multipart body for writing: \(error.localizedDescription)")
        }
        defer { try? output.close() }

        var total: Int64 = 0
        func append(_ string: String) throws {
            let data = Data(string.utf8)
            try output.write(contentsOf: data)
            total += Int64(data.count)
        }

        for (name, value) in fields {
            try append("--\(boundary)\r\n")
            try append("Content-Disposition: form-data; name=\"\(escape(name))\"\r\n\r\n")
            try append(value)
            try append("\r\n")
        }

        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"\(escape(fileField))\"; filename=\"\(escape(filename))\"\r\n")
        try append("Content-Type: \(mimeType)\r\n\r\n")

        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: file)
        } catch {
            throw CloudConvertError.fileNotReadable(file, underlying: error.localizedDescription)
        }
        defer { try? input.close() }

        while true {
            try Task.checkCancellation()
            if isCancelled() { throw CloudConvertError.cancelled }
            let chunk: Data?
            do {
                chunk = try input.read(upToCount: chunkSize)
            } catch {
                throw CloudConvertError.fileNotReadable(file, underlying: error.localizedDescription)
            }
            guard let chunk, !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            total += Int64(chunk.count)
        }

        try append("\r\n--\(boundary)--\r\n")

        return MultipartFormBody(fileURL: destination,
                                 contentType: "multipart/form-data; boundary=\(boundary)",
                                 contentLength: total)
    }

    /// RFC 7578: percent-encode quotes and strip CR/LF from field names and filenames.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "%22")
    }

    /// Best-effort MIME type from the file extension; CloudConvert does not
    /// rely on it but S3-style endpoints like to see one.
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        case "svg": return "image/svg+xml"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "epub": return "application/epub+zip"
        case "mobi": return "application/x-mobipocket-ebook"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "doc": return "application/msword"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}

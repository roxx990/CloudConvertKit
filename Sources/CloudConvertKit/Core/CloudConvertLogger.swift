//  Pluggable logging so each app can route to its own analytics / crash
//  reporter. The default writes to the unified logging system.
//

import Foundation
import os

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, notice, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public protocol CloudConvertLogging: Sendable {
    /// `message` is operational: ids, phases, status and analytics codes.
    /// Anything that can identify what the user converts (file names, the
    /// server's messages, response bodies) comes in `metadata`, which the
    /// default logger records as private.
    func log(_ level: LogLevel, _ message: @autoclosure () -> String, metadata: [String: String])
}

public extension CloudConvertLogging {
    func debug(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.debug, message(), metadata: metadata)
    }
    func info(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.info, message(), metadata: metadata)
    }
    func notice(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.notice, message(), metadata: metadata)
    }
    func warning(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.warning, message(), metadata: metadata)
    }
    func error(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.error, message(), metadata: metadata)
    }
}

/// Default logger backed by `os.Logger`. Messages are public; metadata is
/// private, so it reads `<private>` unless private data is enabled (for
/// example while the debugger is attached).
public struct OSLogCloudConvertLogger: CloudConvertLogging {

    private let logger: Logger
    private let minimumLevel: LogLevel

    public init(subsystem: String = Bundle.main.bundleIdentifier ?? "CloudConvertKit",
                category: String = "CloudConvert",
                minimumLevel: LogLevel = .debug) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.minimumLevel = minimumLevel
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String, metadata: [String: String]) {
        guard level >= minimumLevel else { return }
        let type: OSLogType
        switch level {
        case .debug: type = .debug
        case .info: type = .info
        case .notice: type = .default
        case .warning, .error: type = .error
        }
        let text = message()
        if metadata.isEmpty {
            logger.log(level: type, "\(text, privacy: .public)")
        } else {
            let details = metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            logger.log(level: type, "\(text, privacy: .public) \(details, privacy: .private)")
        }
    }
}

/// Discards everything. Handy for tests.
public struct SilentCloudConvertLogger: CloudConvertLogging {
    public init() {}
    public func log(_ level: LogLevel, _ message: @autoclosure () -> String, metadata: [String: String]) {}
}

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

/// Default logger backed by `os.Logger`.
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
        let suffix = metadata.isEmpty ? "" : " " + metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let text = message() + suffix
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .notice: logger.notice("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
    }
}

/// Discards everything. Handy for tests.
public struct SilentCloudConvertLogger: CloudConvertLogging {
    public init() {}
    public func log(_ level: LogLevel, _ message: @autoclosure () -> String, metadata: [String: String]) {}
}

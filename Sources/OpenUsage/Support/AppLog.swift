import Foundation
import os

enum LogTag: String, Sendable {
    case refresh
    case cache
    case http
    case auth
    case updates
    case config
    case statusItem = "statusitem"
    case lifecycle
    case notifications

    static func plugin(_ id: String) -> String { "plugin:\(id)" }
    static func auth(_ id: String) -> String { "auth:\(id)" }
}

enum AppLog {
    private enum Level {
        case error, warn, notice, info, debug

        var osType: OSLogType {
            switch self {
            case .error: .error
            case .warn, .notice: .default
            case .info: .info
            case .debug: .debug
            }
        }
    }

    private static let loggerLock = NSLock()
    private nonisolated(unsafe) static var loggers: [String: Logger] = [:]

    static func bootstrap() {
        info(.config, "OpenUsage \(AppInfo.version) starting")
    }

    static func error(_ tag: String, _ message: @autoclosure () -> String) { emit(.error, tag, message) }
    static func warn(_ tag: String, _ message: @autoclosure () -> String) { emit(.warn, tag, message) }
    static func info(_ tag: String, _ message: @autoclosure () -> String) { emit(.info, tag, message) }
    static func debug(_ tag: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        emit(.debug, tag, message)
        #endif
    }

    static func error(_ tag: LogTag, _ message: @autoclosure () -> String) { error(tag.rawValue, message()) }
    static func warn(_ tag: LogTag, _ message: @autoclosure () -> String) { warn(tag.rawValue, message()) }
    static func info(_ tag: LogTag, _ message: @autoclosure () -> String) { info(tag.rawValue, message()) }
    /// Unified logging keeps info lines in memory only, so `log show` an hour later misses them; a
    /// notice is written to disk. For the lines read after the fact to check what the app did, such as
    /// each refresh pass's start and end.
    static func notice(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.notice, tag.rawValue, message) }
    static func debug(_ tag: LogTag, _ message: @autoclosure () -> String) {
        #if DEBUG
        emit(.debug, tag.rawValue, message)
        #endif
    }

    private static func emit(_ level: Level, _ tag: String, _ message: () -> String) {
        let redacted = LogRedaction.redactLogMessage(message())
        logger(for: tag).log(level: level.osType, "[\(tag, privacy: .public)] \(redacted, privacy: .public)")
    }

    private static func logger(for tag: String) -> Logger {
        loggerLock.lock()
        defer { loggerLock.unlock() }
        if let existing = loggers[tag] { return existing }
        let logger = Logger(subsystem: "OpenUsage", category: tag)
        loggers[tag] = logger
        return logger
    }
}

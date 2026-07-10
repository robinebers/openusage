import Foundation

/// Subsystem tags that prefix every log line.
public enum LogTag: String, Sendable {
    case refresh
    case cache
    case http
    case auth
    case keychain
    case menubar
    case updates
    case config
    case statusItem = "statusitem"
    case localAPI = "localapi"
    case subprocess
    case lifecycle
    case notifications

    static func plugin(_ id: String) -> String { "plugin:\(id)" }
    static func auth(_ id: String) -> String { "auth:\(id)" }
}

/// Portable print-based logger stub for the Windows core spike (replaces macOS `os.Logger` + `LogFile`).
public enum AppLog {
    nonisolated(unsafe) static var sink: LogFile = .shared

    public static func bootstrap() {
        sink.open()
        reloadLevel()
    }

    static func reloadLevel() {}
    static func reloadLevel(_ level: LogLevelSetting) {}

    static func error(_ tag: String, _ message: @autoclosure () -> String) { emit("ERROR", tag, message()) }
    static func warn(_ tag: String, _ message: @autoclosure () -> String) { emit("WARN", tag, message()) }
    static func info(_ tag: String, _ message: @autoclosure () -> String) { emit("INFO", tag, message()) }
    static func debug(_ tag: String, _ message: @autoclosure () -> String) { emit("DEBUG", tag, message()) }

    static func error(_ tag: LogTag, _ message: @autoclosure () -> String) { emit("ERROR", tag.rawValue, message()) }
    static func warn(_ tag: LogTag, _ message: @autoclosure () -> String) { emit("WARN", tag.rawValue, message()) }
    public static func info(_ tag: LogTag, _ message: @autoclosure () -> String) { emit("INFO", tag.rawValue, message()) }
    static func debug(_ tag: LogTag, _ message: @autoclosure () -> String) { emit("DEBUG", tag.rawValue, message()) }

    private static func emit(_ level: String, _ tag: String, _ message: String) {
        let timestamp = OpenUsageISO8601.string(from: Date())
        let line = "\(timestamp) [\(level)] [\(tag)] \(message)"
        print(line)
        sink.append(line)
    }
}

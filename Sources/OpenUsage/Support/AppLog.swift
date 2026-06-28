import Foundation
import os

/// Subsystem tags that prefix every log line, keeping lines grep-friendly (`[refresh]`, `[cache]`,
/// `[plugin:claude]`, …). The raw value is the bracketed text and the `os.Logger` category.
enum LogTag: String, Sendable {
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

    /// Compound `[plugin:<id>]` / `[auth:<id>]` tags for per-provider lines.
    static func plugin(_ id: String) -> String { "plugin:\(id)" }
    static func auth(_ id: String) -> String { "auth:\(id)" }
}

/// The one consolidated logging facility. The user's `LogLevelSetting` is a single floor that governs
/// BOTH sinks. Each call:
///   1. drops the line immediately if its severity is below the current floor — before the message is
///      even built (so the `@autoclosure` truly defers) and before any redaction runs,
///   2. otherwise runs the message through `LogRedaction.redactLogMessage` as a lightweight last line
///      of defense, then fans out to a per-category `os.Logger` and a grep-friendly `LogFile` line
///      (`ISO8601 [LEVEL] [tag] msg`).
///
/// `redactLogMessage` is URL/body-unaware (matching the Tauri `redact_log_message`): any call site that
/// logs a URL or response body MUST pre-redact it via `LogRedaction.redactURL` / `bodyPreview`.
///
/// `os.Logger` has no runtime level gate of its own, so the floor is enforced here for both sinks.
/// Errors (severity 0) always clear any floor, so they are never suppressed. Raising the level to
/// Debug in Settings is what surfaces debug lines in both the file and `log stream` (see
/// `docs/debugging.md`) — matching #604's "Debug only when the user opts in".
///
/// The level is cached (not re-read from `UserDefaults` on every call, which would be wasteful on the
/// hot `[http]`/`[cache]` paths) and refreshed by `reloadLevel()` from the Settings `.onChange` and at
/// `bootstrap()`. A programmatic `UserDefaults` write outside the picker won't propagate until the next
/// `reloadLevel()` — acceptable since the picker is the only writer.
enum AppLog {
    private enum Level: Int {
        case error = 0
        case warn = 1
        case info = 2
        case debug = 3

        var label: String {
            switch self {
            case .error: "ERROR"
            case .warn: "WARN"
            case .info: "INFO"
            case .debug: "DEBUG"
            }
        }

        var osType: OSLogType {
            switch self {
            case .error: .error
            case .warn: .default
            case .info: .info
            case .debug: .debug
            }
        }
    }

    /// Cached level floor (severity ordinal), guarded by a lock so any isolation can read it cheaply.
    private static let levelLock = NSLock()
    private nonisolated(unsafe) static var cachedSeverity = LogLevelSetting.fallback.severity

    /// Per-category `os.Logger` cache, guarded by its own lock.
    private static let loggerLock = NSLock()
    private nonisolated(unsafe) static var loggers: [String: Logger] = [:]

    /// The file sink. Injectable so tests can point it at a temp directory and assert what the level
    /// gate actually writes; production uses the shared `~/Library/Logs/OpenUsage/OpenUsage.log` appender.
    nonisolated(unsafe) static var sink: LogFile = .shared

    // MARK: - Lifecycle

    /// Open/trim the file, seed the cached level, and emit one startup line. Call FIRST at launch,
    /// before any other subsystem logs. Idempotent in practice (the file `open()` is idempotent).
    static func bootstrap() {
        sink.open()
        reloadLevel()
        let level = LogLevelSetting.current
        // Abbreviate `$HOME` to `~` so the path survives `redactLogMessage` (which masks `/Users/...`)
        // and the startup line actually self-documents where the log lives.
        let displayPath = (LogFile.url.path as NSString).abbreviatingWithTildeInPath
        info(LogTag.config.rawValue,
             "OpenUsage v\(AppInfo.version) starting (level=\(level.rawValue), log=\(displayPath))")
    }

    /// Re-read the persisted level into the cache. Invoked from the Settings picker `.onChange` so a
    /// level change applies live with no restart (mirrors Tauri's `log::set_max_level`).
    static func reloadLevel() {
        apply(LogLevelSetting.current.severity)
    }

    /// Apply a level directly, bypassing `UserDefaults`. The seam tests use to exercise the gate
    /// without racing on global `UserDefaults.standard` state.
    static func reloadLevel(_ level: LogLevelSetting) {
        apply(level.severity)
    }

    private static func apply(_ severity: Int) {
        levelLock.lock()
        cachedSeverity = severity
        levelLock.unlock()
    }

    // MARK: - Public API

    /// `@autoclosure` defers the interpolation: a line below the current level floor is dropped before
    /// its message is built, so a `debug` line genuinely costs nothing when the level is Info.
    static func error(_ tag: String, _ message: @autoclosure () -> String) { emit(.error, tag, message) }
    static func warn(_ tag: String, _ message: @autoclosure () -> String) { emit(.warn, tag, message) }
    static func info(_ tag: String, _ message: @autoclosure () -> String) { emit(.info, tag, message) }
    static func debug(_ tag: String, _ message: @autoclosure () -> String) { emit(.debug, tag, message) }

    // Convenience overloads for the typed tags (the common case).
    static func error(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.error, tag.rawValue, message) }
    static func warn(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.warn, tag.rawValue, message) }
    static func info(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.info, tag.rawValue, message) }
    static func debug(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.debug, tag.rawValue, message) }

    // MARK: - Emit

    private static func emit(_ level: Level, _ tag: String, _ message: () -> String) {
        // Gate first: a line below the floor builds no message, runs no redaction, hits no sink. The
        // floor governs both os_log and the file, so the level picker is a single honest knob. Errors
        // (severity 0) clear any floor and are never suppressed.
        levelLock.lock()
        let floor = cachedSeverity
        levelLock.unlock()
        guard level.rawValue <= floor else { return }

        let redacted = LogRedaction.redactLogMessage(message())

        logger(for: tag).log(level: level.osType, "[\(tag, privacy: .public)] \(redacted, privacy: .public)")

        let timestamp = OpenUsageISO8601.string(from: Date())
        sink.append("\(timestamp) [\(level.label)] [\(tag)] \(redacted)")
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

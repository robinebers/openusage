import Foundation

/// The persisted log level that gates the file log. A `String`-raw `UserDefaultsBacked` enum so it
/// reads its stored choice through the same idiom as every other persisted setting.
///
/// The key (`logLevel`) and the lowercase raw values (`error`/`warn`/`info`/`debug`) mirror the
/// original Tauri store so the strings stay grep-friendly and recognizable across the two editions.
/// The fallback is `.info`, not the Tauri runtime's `Error` default: per issue #604 the release
/// default stays quiet at Info, and Debug is something the user opts into. `Trace` is intentionally
/// dropped — the issue's floor is Error/Warn/Info/Debug and `os.Logger` has no Trace tier — and
/// `off` is not exposed (the tray never produced it).
enum LogLevelSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case error
    case warn
    case info
    case debug

    /// Mirrors the Tauri store key. Harmless to share the name: the two editions never read each
    /// other's store.
    static let key = "logLevel"

    /// The value used when the key is unset or holds an unrecognized raw value. `.info` is the
    /// release default per issue #604; Debug is opt-in only and never the implicit default.
    static var fallback: LogLevelSetting { .info }

    /// Title-case label for the Settings picker.
    var label: String {
        switch self {
        case .error: "Error"
        case .warn: "Warning"
        case .info: "Info"
        case .debug: "Debug"
        }
    }

    /// Higher is more verbose. A line emitted at `lineLevel` is written to the file when
    /// `lineLevel.severity <= self.severity` — i.e. the line is at least as severe as the floor.
    var severity: Int {
        switch self {
        case .error: 0
        case .warn: 1
        case .info: 2
        case .debug: 3
        }
    }
}

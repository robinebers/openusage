import Foundation

/// How much the app writes to unified logging. The key and raw values are 0.7.x's, so a saved choice
/// still applies.
enum LogLevelSetting: String, Hashable, Sendable, CaseIterable {
    case error
    case warn
    case info
    case debug

    static let key = "logLevel"

    static var current: LogLevelSetting { UserDefaults.standard.enumValue(forKey: key, default: .info) }

    var label: String {
        switch self {
        case .error: "Error"
        case .warn: "Warning"
        case .info: "Info"
        case .debug: "Debug"
        }
    }

    func includes(_ line: LogLevelSetting) -> Bool {
        line.verbosity <= verbosity
    }

    private var verbosity: Int {
        switch self {
        case .error: 0
        case .warn: 1
        case .info: 2
        case .debug: 3
        }
    }
}

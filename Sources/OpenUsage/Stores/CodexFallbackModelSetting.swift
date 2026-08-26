import Foundation

enum CodexFallbackModelSetting {
    static let key = "openusage.codex.fallbackModel"
    static let none = ""

    static func current(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: key) ?? none
        return value.isEmpty ? nil : value
    }
}

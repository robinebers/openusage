import Foundation

/// How Claude logins become dashboard cards. `separate` (default) gives each account and organization
/// its own card, pinned to that identity. `activeLogin` keeps one Claude card that follows whichever
/// login Claude Code holds right now — for people who swap accounts in place (`claude login` again, a
/// switcher tool) and don't want a card per account, or a card stuck on a login that has since been
/// swapped out. Cards are built once at launch, so a change applies the next time the app starts.
enum ClaudeAccountsSetting: String, CaseIterable {
    case separate
    case activeLogin

    static let key = "openusage.claude.accounts"

    var label: String {
        switch self {
        case .separate: "Per Account"
        case .activeLogin: "Active Login"
        }
    }

    static func current(defaults: UserDefaults = .standard) -> ClaudeAccountsSetting {
        defaults.string(forKey: key).flatMap(ClaudeAccountsSetting.init(rawValue:)) ?? .separate
    }
}

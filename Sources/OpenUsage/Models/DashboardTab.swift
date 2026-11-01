import Foundation

enum DashboardTab: String, Hashable, Sendable, CaseIterable {
    /// The tab the panel opens to, no matter which tab it was closed on.
    static let defaultKey = "defaultDashboardTab"

    case priority
    case allUsage

    static func preferred(in defaults: UserDefaults = .standard) -> Self {
        defaults.enumValue(forKey: defaultKey, default: .priority)
    }

    var label: String {
        switch self {
        case .priority: "Priority"
        case .allUsage: "All Usage"
        }
    }
}

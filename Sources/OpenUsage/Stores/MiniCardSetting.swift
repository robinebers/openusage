import Foundation

/// Whether a provider section can be collapsed to a single header line, a "mini card". Off by
/// default: turning it on only adds the affordance (hovering a provider's mark or name turns the
/// mark into a chevron), and it never collapses anything on its own. Which providers are currently
/// collapsed is layout state, not a setting, so it lives in `LayoutStore.miniCardProviderIDs`
/// alongside the caret's `expandedProviderIDs`.
enum MiniCardSetting {
    static let key = "miniCardsEnabled"
    static let fallback = false
}

/// The collapsed layout a mini card uses. Both keep the provider mark and name on the header line;
/// they differ in where the meters go and how much room the header has to give up for them.
enum MiniCardStyle: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    /// Meters ride on the header line as a segmented pill at the trailing edge. The tightest form:
    /// the plan badge folds away and a long provider name truncates to make room.
    case singleRow
    /// Meters get their own line under the header, each labeled with its metric name. Roomier, and
    /// the header keeps its plan badge and full name.
    case detailed

    static let key = "miniCardStyle"
    static var fallback: MiniCardStyle { .singleRow }

    var label: String {
        switch self {
        case .singleRow: return "Single Row"
        case .detailed: return "Detailed"
        }
    }
}

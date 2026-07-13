import Foundation

/// Which side of Cursor's usage the spend tiles (Today / Yesterday / Last 30 Days) and the Usage
/// Trend aggregate: everything, only plan-covered rows (the export's `Cost` column says `Included`),
/// or only billed / on-demand rows (the column carries a dollar amount). The bounded meters
/// (Total / Auto / API Usage %) always stay as Cursor reports them — they come from Cursor's live
/// API, not the export, and re-deriving them locally would contradict the dashboard.
///
/// Rows an old export can't classify (no `Cost` column) only count in All Usage: quietly assigning
/// them to a side would fake the split.
enum CursorSpendViewSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case all
    case included
    case api

    static let key = "cursor.spendView"
    static var fallback: CursorSpendViewSetting { .all }

    // `current` (the user's current choice, read live) comes from `UserDefaultsBacked`.

    var label: String {
        switch self {
        case .all: return "All Usage"
        case .included: return "Included Usage"
        case .api: return "API Usage"
        }
    }

    /// Whether a CSV row with this billing kind counts in this view.
    func includes(_ billing: CursorBillingKind) -> Bool {
        switch self {
        case .all: return true
        case .included: return billing == .included
        case .api: return billing == .billed
        }
    }
}

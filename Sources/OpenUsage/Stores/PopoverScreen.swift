import Foundation

/// The screen showing inside the menu-bar popover. Customize and Settings replace the dashboard
/// in place (the popover has no window stack); Esc backs out to the dashboard first.
enum PopoverScreen: Hashable, Sendable {
    case dashboard
    case customize
    case settings

    /// Left-to-right order for the popover's horizontal screen-switch slide: the dashboard is home on
    /// the left, with Customize and Settings to its right. The slide reads its direction from these
    /// ranks — a higher-ranked target enters from the trailing edge, a lower one from the leading edge.
    var slideRank: Int {
        switch self {
        case .dashboard: 0
        case .customize: 1
        case .settings: 2
        }
    }
}

import Observation

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

/// In-popover navigation: which screen is showing, the master/detail route inside Customize, and the
/// horizontal screen-switch slide bookkeeping. Split out of `LayoutStore` (which owns the *layout* —
/// enabled widgets, order, pins) so screen routing is its own concern; `LayoutStore` forwards its
/// existing `screen`/`isEditing`/`customizeProviderID`/`screenSlide*` surface to this store, so callers
/// are unchanged.
@MainActor
@Observable
final class PopoverNavigationStore {
    /// Which in-popover screen is showing. Drives the footer buttons, the Esc handler, and the
    /// popover-closed reset alike.
    var screen = PopoverScreen.dashboard {
        didSet {
            guard screen != oldValue else { return }
            // Recorded synchronously with the change — not via SwiftUI's `onChange`, which fires a
            // frame later and would let the popover paint the destination before the slide begins.
            // DashboardView reads these on its very next render to slide in from the screen being left.
            screenSlideFrom = oldValue
            screenSlideID += 1
            // Leaving Customize drops the L2 detail selection so reopening Customize shows the list,
            // never a stranded detail screen. The popover-closed reset sets `screen = .dashboard`, so
            // this also covers close/reopen.
            if screen != .customize { customizeProviderID = nil }
        }
    }
    /// Supports DashboardView's horizontal screen-switch slide: the screen being left, plus a counter
    /// that ticks on every switch so the view can detect and animate each transition. UI-only; not persisted.
    private(set) var screenSlideFrom = PopoverScreen.dashboard
    private(set) var screenSlideID = 0
    /// Whether the Customize screen is showing — a bridge over `screen` for the many call sites that
    /// think in terms of edit mode.
    var isEditing: Bool {
        get { screen == .customize }
        set { screen = newValue ? .customize : .dashboard }
    }
    /// The provider whose Customize detail (L2) is showing. nil shows the provider list (L1); a set id
    /// shows that provider's metric sections and API key. UI-only (not persisted): cleared when leaving
    /// Customize (see `screen`'s didSet) and on popover close.
    var customizeProviderID: String?
}

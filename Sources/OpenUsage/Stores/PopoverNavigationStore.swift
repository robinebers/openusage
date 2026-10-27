import Observation

/// The screen showing inside the menu-bar popover. Accounts and Settings replace the dashboard
/// in place (the popover has no window stack); Esc backs out to the dashboard first.
enum PopoverScreen: Hashable, Sendable {
    case dashboard
    case accounts
    case settings

    /// Left-to-right order for the popover's horizontal screen-switch slide: the dashboard is home on
    /// the left, with Accounts and Settings to its right. The slide reads its direction from these
    /// ranks — a higher-ranked target enters from the trailing edge, a lower one from the leading edge.
    var slideRank: Int {
        switch self {
        case .dashboard: 0
        case .accounts: 1
        case .settings: 2
        }
    }
}

/// In-popover navigation: which screen is showing, the master/detail route inside Accounts, and the
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
            // Leaving Accounts drops the L2 detail selection so reopening Accounts shows the list,
            // never a stranded detail screen. The popover-closed reset sets `screen = .dashboard`, so
            // this also covers close/reopen.
            if screen != .accounts {
                customizeProviderID = nil
                isAddingAccount = false
            }
        }
    }
    /// Supports DashboardView's horizontal screen-switch slide: the screen being left, plus a counter
    /// that ticks on every switch so the view can detect and animate each transition. UI-only; not persisted.
    private(set) var screenSlideFrom = PopoverScreen.dashboard
    private(set) var screenSlideID = 0
    /// Whether the Accounts screen is showing — a bridge over `screen` for the call sites that
    /// think in terms of edit mode.
    var isEditing: Bool {
        get { screen == .accounts }
        set { screen = newValue ? .accounts : .dashboard }
    }
    /// The account whose Accounts detail (L2) is showing. nil shows the account list (L1); a set id
    /// shows that account's name and metric sections. UI-only (not persisted): cleared when leaving
    /// Accounts (see `screen`'s didSet) and on popover close.
    var customizeProviderID: String?
    /// Whether the Add Account sheet is showing over the account list. The top bar's + opens it.
    /// Cleared when leaving Accounts, so it never reopens stale.
    var isAddingAccount = false
    /// Whether the popover is on-screen. `StatusItemController` flips it at its show/hide chokepoints,
    /// synchronously with `makeKeyAndOrderFront`/`orderOut`, and `DashboardView` re-seeds the panel
    /// height on reopen from it. Deliberately not derived from occlusion or window key state: a
    /// `.canJoinAllSpaces` panel is briefly fully occluded mid Space-switch while still following the
    /// user on-screen. Never persisted.
    var popoverShown = false
}

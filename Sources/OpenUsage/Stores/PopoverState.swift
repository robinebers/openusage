import Observation
import SwiftUI

enum PopoverScreen: Hashable, Sendable {
    case dashboard
    case accounts
    case settings

    var slideRank: Int {
        switch self {
        case .dashboard: 0
        case .accounts: 1
        case .settings: 2
        }
    }
}

@MainActor
@Observable
final class PopoverState {
    var screen = PopoverScreen.dashboard {
        didSet {
            guard screen != oldValue else { return }
            // Recorded synchronously with the change — not via SwiftUI's `onChange`, which fires a
            // frame later and would let the popover paint the destination before the slide begins.
            // DashboardView reads these on its very next render to slide in from the screen being left.
            screenSlideFrom = oldValue
            screenSlideID += 1
            if screen != .accounts {
                customizeProviderID = nil
                isAddingAccount = false
            }
        }
    }
    private(set) var screenSlideFrom = PopoverScreen.dashboard
    private(set) var screenSlideID = 0
    var customizeProviderID: String?
    var isAddingAccount = false
    private(set) var dashboardFocusProviderID: String?
    private(set) var dashboardFocusRequestID = 0
    /// Whether the popover is on-screen. `StatusItemController` flips it at its show/hide chokepoints,
    /// synchronously with `makeKeyAndOrderFront`/`orderOut`, and `DashboardView` re-seeds the panel
    /// height on reopen from it. Deliberately not derived from occlusion or window key state: a
    /// `.canJoinAllSpaces` panel is briefly fully occluded mid Space-switch while still following the
    /// user on-screen. Never persisted.
    var popoverShown = false

    let pinNotice = TransientNotice<String?>(clearedValue: nil, timeout: .seconds(3))
    let shareNotice = TransientNotice<Bool>(clearedValue: false, timeout: .seconds(2.5))
    let accountsNotice = TransientNotice<CustomizationNoticeContent?>(clearedValue: nil, timeout: .seconds(2.5))

    @discardableResult
    func back() -> Bool {
        if customizeProviderID != nil {
            withAnimation(Motion.spring) { customizeProviderID = nil }
            return true
        }
        guard screen != .dashboard else { return false }
        withAnimation(Motion.modeSwitch) { screen = .dashboard }
        return true
    }

    func toggle(_ target: PopoverScreen) {
        withAnimation(Motion.modeSwitch) { screen = screen == target ? .dashboard : target }
    }

    func openAccounts(_ providerID: String?) {
        withAnimation(Motion.modeSwitch) {
            customizeProviderID = providerID
            screen = .accounts
        }
    }

    func reset() {
        if screen != .dashboard { screen = .dashboard }
        shareNotice.clear()
        accountsNotice.clear()
        dashboardFocusProviderID = nil
    }

    func openWidgetAccount(_ providerID: String?, hasVisibleMetrics: Bool) {
        dashboardFocusProviderID = nil
        isAddingAccount = false
        if let providerID, !hasVisibleMetrics {
            openAccounts(providerID)
        } else {
            screen = .dashboard
            if let providerID {
                dashboardFocusProviderID = providerID
                dashboardFocusRequestID &+= 1
            }
        }
    }

    func acknowledgeDashboardFocus(requestID: Int) {
        guard requestID == dashboardFocusRequestID else { return }
        dashboardFocusProviderID = nil
    }
}

import SwiftUI

/// The Accounts screen, a two-level master/detail: the account list (L1) or, when
/// `popover.customizeProviderID` is set, that account's detail (L2). The two slide horizontally — L2
/// enters from the trailing edge, L1 returns from the leading edge — on the same spring. The back
/// chevron (handled in `PopoverTopBar`) is context-aware: L2 → L1, L1 → dashboard.
///
/// Reordering uses `DragGesture` plus local row geometry, kept inside the menu-bar popover instead
/// of SwiftUI's pasteboard-backed drag/drop (unreliable here). The router owns the scroll view and
/// the reorder-frame map; L1 and L2 read it for their drag hit-testing and emit frames via
/// `.reorderFrame`. The `customizeProviderID` route lives in `PopoverState` so the popover-closed
/// reset and the Esc handler drive the same state.
struct AccountsView: View {
    @Environment(PopoverState.self) private var popover
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var frameStore = ReorderFrameStore()

    var body: some View {
        PopoverScrollView {
            content
                .padding(PanelMetrics.margin)
                .frame(maxWidth: .infinity)
        }
        .onPreferenceChange(ReorderFramePreferenceKey.self) { frameStore.frames = $0 }
        // The transient star/denial pill floats above the detail content — the same capsule style as
        // the dashboard's "Copied to clipboard" share pill. Green for a successful star/unstar, orange
        // for the per-provider cap denial.
        .overlay(alignment: .bottom) {
            if popover.accountsNotice.value != nil {
                customizationNoticePill
                    .padding(.bottom, 12)
            }
        }
        .animation(Motion.spring, value: popover.accountsNotice.value?.message)
        .animation(Motion.spring, value: popover.accountsNotice.trigger)
    }

    private var customizationNoticePill: some View {
        let isNotice = popover.accountsNotice.value?.tone == .notice
        return TransientPill(
            systemImage: isNotice ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            text: popover.accountsNotice.value?.message ?? "",
            tint: isNotice ? Theme.notice : Theme.positive,
            trigger: popover.accountsNotice.trigger,
            showsShadow: false
        )
    }

    /// Both levels share one ZStack so the outgoing and incoming level overlap while they slide instead
    /// of stacking.
    private var content: some View {
        ZStack(alignment: .top) {
            level
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var level: some View {
        if let id = popover.customizeProviderID {
            AccountDetailView(
                providerID: id,
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift,
                frameStore: frameStore
            )
            .transition(.move(edge: .trailing))
        } else {
            AccountListView(
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift,
                frameStore: frameStore
            )
            .transition(.move(edge: .leading))
        }
    }
}

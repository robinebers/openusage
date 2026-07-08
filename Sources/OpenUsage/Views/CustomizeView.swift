import SwiftUI

/// The Customize screen, now a two-level master/detail: the provider list (L1) or, when
/// `layout.customizeProviderID` is set, that provider's detail (L2). The two slide horizontally — L2
/// enters from the trailing edge, L1 returns from the leading edge — on the same spring. The back
/// chevron (handled in `DashboardView`) is context-aware: L2 → L1, L1 → dashboard.
///
/// Reordering uses `DragGesture` plus local row geometry, kept inside the menu-bar popover instead
/// of SwiftUI's pasteboard-backed drag/drop (unreliable here). The router owns the scroll view and
/// the reorder-frame map; L1 and L2 read it for their drag hit-testing and emit frames via
/// `.reorderFrame`. The `customizeProviderID` route lives in `LayoutStore` so the popover-closed
/// reset and the Esc handler drive the same state.
struct CustomizeView: View {
    @Environment(LayoutStore.self) private var layout
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var rowFrames: [String: CGRect] = [:]

    var body: some View {
        PopoverScrollView {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .onPreferenceChange(ReorderFramePreferenceKey.self) { rowFrames = $0 }
        // The transient star/denial pill floats above the Customize content — the same capsule style
        // as the dashboard's "Copied to clipboard" share pill. Green for a successful star/unstar,
        // orange for the per-provider cap denial.
        .overlay(alignment: .bottom) {
            if layout.customizationNotice != nil {
                customizationNoticePill
                    .padding(.bottom, 12)
            }
        }
        .animation(Motion.spring, value: layout.customizationNotice)
        .animation(Motion.spring, value: layout.customizationNoticeTrigger)
    }

    private var customizationNoticePill: some View {
        let isNotice = layout.customizationNoticeTone == .notice
        return TransientPill(
            systemImage: isNotice ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            text: layout.customizationNotice ?? "",
            tint: isNotice ? Theme.notice : Theme.positive,
            trigger: layout.customizationNoticeTrigger,
            showsShadow: false
        )
    }

    @ViewBuilder
    private var content: some View {
        if let id = layout.customizeProviderID {
            CustomizeProviderDetailView(
                providerID: id,
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift,
                rowFrames: rowFrames
            )
            .transition(.move(edge: .trailing))
        } else {
            CustomizeProviderListView(
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift,
                rowFrames: rowFrames
            )
            .transition(.move(edge: .leading))
        }
    }
}

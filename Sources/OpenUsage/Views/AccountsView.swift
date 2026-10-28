import SwiftUI

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

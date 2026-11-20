import SwiftUI

struct AccountsView: View {
    @Environment(PopoverState.self) private var popover
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    /// Inside the scroll view, so the scroll view's insets for the bars don't animate with the page.
    let pageAnimation: Animation?

    @State private var frameStore = ReorderFrameStore()

    var body: some View {
        PopoverScrollView {
            content
                .animation(pageAnimation, value: popover.accountsPage)
                .padding(.horizontal, PanelMetrics.margin)
                .padding(.top, DashboardContentView.barGap)
                .padding(.bottom, popover.customizeProviderID == nil && popover.customizeHubID == nil ? 0 : PanelMetrics.margin)
                .frame(maxWidth: .infinity)
        }
        .onPreferenceChange(ReorderFramePreferenceKey.self) { frameStore.frames = $0 }
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
        } else if let hubID = popover.customizeHubID {
            HubDetailView(hubID: hubID)
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

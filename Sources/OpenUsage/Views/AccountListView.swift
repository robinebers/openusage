import SwiftUI

struct AccountListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let frameStore: ReorderFrameStore

    @State private var activeProviderID: String?

    var body: some View {
        let providers = layout.orderedProviders()
        let hubs = CLIProxyHub.isEnabled ? container.accounts.hubs : []
        VStack(spacing: PanelMetrics.sectionSpacing) {
            if providers.isEmpty, hubs.isEmpty {
                ContentUnavailableView { Label("No Accounts", systemImage: "person.crop.circle") }
            } else if !providers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(providers) { provider in
                        accountRow(provider)
                    }
                }
                .cardSurface()
            }
            ForEach(hubs) { hub in
                CLIProxyHubRow(hub: hub)
            }
        }
        .animation(Motion.spring, value: providers.map(\.id))
        .animation(Motion.spring, value: hubs.map(\.id))
    }

    private func accountRow(_ provider: Provider) -> some View {
        AccountListRow(
            provider: provider,
            grip: { ReorderGrip().highPriorityGesture(accountDragGesture(for: provider)) },
            onOpen: { withAnimation(Motion.spring) { popover.customizeProviderID = provider.id } }
        )
        .opacity(activeProviderID == provider.id ? 0 : 1)
        .reorderFrame(id: provider.id, in: .named(reorderSpaceName))
    }

    private func accountDragGesture(for provider: Provider) -> some Gesture {
        reorderDragGesture(
            id: provider.id,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { value in
                ReorderLift.make(
                    id: provider.id,
                    preview: AnyView(AccountListRow(provider: provider, grip: { ReorderGrip() }).liftedRowSurface()),
                    value: value,
                    frames: frameStore.frames
                )
            },
            orderedIDs: { layout.orderedProviders().map(\.id) },
            reorder: { layout.reorderProvider(dragged: provider.id, target: $0) }
        )
    }
}

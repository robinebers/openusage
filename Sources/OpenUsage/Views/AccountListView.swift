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
        let providers = directProviders
        let hubs = container.accounts.hubs
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
            if !hubs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(hubs) { hub in
                        CLIProxyHubRow(hub: hub) { withAnimation(Motion.navigation) { popover.customizeHubID = hub.id } }
                    }
                }
                .cardSurface()
            }
        }
        .animation(Motion.spring, value: providers.map(\.id))
        .animation(Motion.spring, value: hubs.map(\.id))
    }

    /// A hub's accounts are listed on its page, not here.
    private var directProviders: [Provider] {
        layout.orderedProviders().filter { $0.hubHost == nil }
    }

    private func accountRow(_ provider: Provider) -> some View {
        AccountListRow(
            provider: provider,
            grip: { ReorderGrip().highPriorityGesture(accountDragGesture(for: provider)) },
            onOpen: { withAnimation(Motion.navigation) { popover.customizeProviderID = provider.id } }
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
            orderedIDs: { directProviders.map(\.id) },
            reorder: { layout.reorderProvider(dragged: provider.id, target: $0) }
        )
    }
}

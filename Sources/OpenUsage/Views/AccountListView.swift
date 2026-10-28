import SwiftUI

/// The Accounts list (L1): every account in the user's saved order, grouped in one card the way
/// Settings groups its rows, or "No Accounts" where the card would be; the top bar's + opens the Add
/// Account sheet. Click a row to open that account (L2); drag its grip to reorder the accounts, which
/// reorders the dashboard too.
struct AccountListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let frameStore: ReorderFrameStore

    @State private var activeProviderID: String?

    var body: some View {
        @Bindable var layout = layout
        let providers = layout.orderedProviders()
        Group {
            if providers.isEmpty {
                ContentUnavailableView { Label("No Accounts", systemImage: "person.crop.circle") }
            } else {
                VStack(spacing: 0) {
                    ForEach(providers) { provider in
                        accountRow(provider)
                    }
                }
                .cardSurface()
            }
        }
        .animation(Motion.spring, value: providers.map(\.id))
        .sheet(isPresented: $layout.isAddingAccount) {
            AddAccountSheet(store: container.accounts)
        }
    }

    private func accountRow(_ provider: Provider) -> some View {
        AccountListRow(
            provider: provider,
            grip: { ReorderGrip().highPriorityGesture(accountDragGesture(for: provider)) },
            onOpen: { withAnimation(Motion.spring) { layout.customizeProviderID = provider.id } }
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

import SwiftUI

/// A CLIProxyAPI hub's page in Accounts: why its last read failed, the accounts it mirrors, the logins
/// OpenUsage can't show yet, and the hub's own key and removal. Each account opens its usual page.
struct HubDetailView: View {
    let hubID: UUID
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    @State private var isConfirmingRemoval = false

    var body: some View {
        if let hub = container.accounts.hubs.first(where: { $0.id == hubID }) {
            let status = container.hubs.status(of: hubID)
            let unsupported = if case .synced(let unsupported) = status { unsupported } else { 0 }
            let mirrored = Set(container.accounts.accounts(onHub: hubID).map(\.cardID))
            let providers = layout.orderedProviders().filter { mirrored.contains($0.id) }
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                if case .failed(let message) = status {
                    ProblemCard(message: message)
                }
                if !providers.isEmpty || unsupported > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        if !providers.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(providers) { provider in
                                    AccountListRow(provider: provider, grip: { EmptyView() }) {
                                        withAnimation(Motion.navigation) { popover.customizeProviderID = provider.id }
                                    }
                                }
                            }
                            .cardSurface()
                        }
                        if unsupported > 0 {
                            Text("\(CLIProxyHub.count(unsupported, "login")) OpenUsage doesn’t support yet")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                        }
                    }
                }
                VStack(spacing: 0) {
                    ReplaceKeyRow(field: "Management Key") { try await container.replaceHubKey($0, for: hubID) }
                    removeRow(hub, accountCount: mirrored.count)
                }
                .cardSurface()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func removeRow(_ hub: CLIProxyHub, accountCount: Int) -> some View {
        Button(role: .destructive) {
            isConfirmingRemoval = true
        } label: {
            Text("Remove Hub…")
                .foregroundStyle(Color(nsColor: .systemRed))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, PanelMetrics.controlRowPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            "Remove the Hub at \(hub.host)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Hub and \(CLIProxyHub.count(accountCount, "Account"))", role: .destructive) {
                container.hubs.remove(hubID)
                if !container.accounts.hubs.contains(where: { $0.id == hubID }) {
                    withAnimation(Motion.navigation) { popover.customizeHubID = nil }
                }
            }
        } message: {
            Text("Its \(CLIProxyHub.count(accountCount, "account")) and its management key are deleted from this Mac. Nothing changes on the hub.")
        }
    }
}

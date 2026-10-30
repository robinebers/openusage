import SwiftUI

/// A connected CLIProxyAPI hub in Accounts: its host, how its last read went, how many accounts it
/// mirrors, and how many of its logins OpenUsage can't show yet. The hub's key is replaced here, and
/// removing the hub removes its accounts with it.
struct CLIProxyHubRow: View {
    let hub: CLIProxyHub
    @Environment(AppContainer.self) private var container
    @State private var isConfirmingRemoval = false

    var body: some View {
        let accountCount = container.accounts.accounts(onHub: hub.id).count
        VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProviderIcon(id: CLIProxyHub.markID, side: 18)
                    Text("CLIProxyAPI")
                        .layoutPriority(1)
                    Text(hub.host)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                status(accountCount: accountCount)
                    .font(.callout)
                    .padding(.leading, 26)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, PanelMetrics.controlRowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            ReplaceKeyRow(field: "Management Key") { try await container.replaceHubKey($0, for: hub.id) }
            removeRow(accountCount: accountCount)
        }
    }

    @ViewBuilder
    private func status(accountCount: Int) -> some View {
        switch container.hubs.status(of: hub.id) {
        case .checking:
            Text("Checking…")
                .foregroundStyle(.secondary)
        case .synced(let unsupported):
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.count(accountCount, "account"))
                    .foregroundStyle(.secondary)
                if unsupported > 0 {
                    Text("\(Self.count(unsupported, "login")) OpenUsage doesn’t support yet")
                        .foregroundStyle(.tertiary)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.notice)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func removeRow(accountCount: Int) -> some View {
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
        .cardSurface()
        .confirmationDialog(
            "Remove the Hub at \(hub.host)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Hub and \(Self.count(accountCount, "Account"))", role: .destructive) {
                withAnimation(Motion.spring) { container.hubs.remove(hub.id) }
            }
        } message: {
            Text("Its \(Self.count(accountCount, "account")) and its management key are deleted from this Mac. Nothing changes on the hub.")
        }
    }

    private static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

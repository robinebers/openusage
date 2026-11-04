import SwiftUI

/// A connected CLIProxyAPI hub in Accounts, laid out like an account's row: its host, how many accounts
/// it mirrors, and a warning when its last read failed. It opens the hub's page.
struct CLIProxyHubRow: View {
    let hub: CLIProxyHub
    let onOpen: () -> Void
    @Environment(AppContainer.self) private var container
    @AppStorage(PrivacyModeSetting.key) private var privacyMode = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                ProviderIcon(id: CLIProxyHub.markID, side: 18)
                Text(PrivacyModeSetting.host(hub.host, isEnabled: privacyMode))
                    .foregroundStyle(.primary)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(CLIProxyHub.count(container.accounts.accounts(onHub: hub.id).count, "account"))
                    .foregroundStyle(.secondary)
                if case .failed(let message) = container.hubs.status(of: hub.id) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.notice)
                        .accessibilityLabel(PrivacyModeSetting.message(message, isEnabled: privacyMode))
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }

            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the CLIProxyAPI Hub at \(PrivacyModeSetting.host(hub.host, isEnabled: privacyMode))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, PanelMetrics.controlRowPadding)
    }
}

extension CLIProxyHub {
    static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

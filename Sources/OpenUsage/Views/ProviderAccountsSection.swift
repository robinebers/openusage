import SwiftUI

/// Customize (L2) section for a provider's extra accounts: one row per account with a rename field
/// and a remove button. Shown only when discovery found more than one login. Renames apply live
/// everywhere the account name shows (the header picker reads the same `@Observable` store); remove
/// forgets the account — its card selection falls back to the default account, and an account whose
/// credentials still exist on the machine is re-found (with a fresh name) on the next launch.
struct ProviderAccountsSection: View {
    @Environment(AppContainer.self) private var container
    let providerID: String

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Accounts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                ForEach(container.providerAccounts.accounts(for: providerID)) { account in
                    ProviderAccountRow(account: account) { newName in
                        container.providerAccounts.setCustomName(newName, forID: account.id)
                    } onRemove: {
                        container.providerAccounts.remove(id: account.id)
                    }
                }
            }
            .cardSurface()
        }
    }
}

/// One account row: name field (placeholder shows the current display name) and the remove control.
private struct ProviderAccountRow: View {
    let account: ProviderAccount
    let onRename: (String) -> Void
    let onRemove: () -> Void

    @State private var name: String

    init(account: ProviderAccount, onRename: @escaping (String) -> Void, onRemove: @escaping () -> Void) {
        self.account = account
        self.onRename = onRename
        self.onRemove = onRemove
        _name = State(initialValue: account.customName ?? "")
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(account.displayName, text: $name)
                .textFieldStyle(.plain)
                .onSubmit { onRename(name) }
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(account.displayName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Commit on leave too, so a rename isn't lost when the user navigates back without Return.
        .onDisappear { onRename(name) }
    }
}

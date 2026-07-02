import AppKit
import SwiftUI

/// The Accounts settings section: lists extra provider accounts and an in-place "Add Account" flow
/// that logs the provider CLI into a per-account config dir. New accounts apply on the next launch
/// (the provider list is built once at startup), so a relaunch prompt appears after a change.
struct AccountsSettingsSection: View {
    @Environment(AppContainer.self) private var container
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    @State private var isAdding = false
    @State private var newProvider = "claude"
    @State private var newLabel = ""
    @State private var loginState: LoginState = .idle
    @State private var changedAccounts = false
    /// Resolved account emails (instanceID -> email), filled in asynchronously so each row can show
    /// which account it is (the reliable profile-API email, not the config-dir path).
    @State private var emails: [String: String] = [:]

    private enum LoginState: Equatable {
        case idle
        case loggingIn
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Accounts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                ForEach(container.accounts.accounts) { account in
                    accountRow(account)
                }
                if container.accounts.accounts.isEmpty, !isAdding {
                    Text("Add Claude or Codex accounts beyond your default login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, density.controlRowPadding)
                }
                if isAdding {
                    addForm
                } else {
                    addButton
                }
                if changedAccounts {
                    relaunchNotice
                }
            }
            .cardSurface()
        }
        .task(id: container.accounts.accounts) {
            await resolveEmails()
        }
    }

    private func resolveEmails() async {
        for account in container.accounts.accounts {
            if emails[account.instanceID] == nil,
               let email = await AccountIdentity.email(provider: account.provider, configDir: account.configDir) {
                emails[account.instanceID] = email
            }
        }
    }

    /// Every email already signed in for `provider` — its default login plus each added account of that
    /// provider, lowercased — so the add flow can reject logging the same account in twice.
    private func existingEmails(forProvider provider: String) async -> Set<String> {
        var result = Set<String>()
        if let defaultEmail = await AccountIdentity.email(provider: provider, configDir: nil) {
            result.insert(defaultEmail.lowercased())
        }
        for account in container.accounts.accounts where account.provider == provider {
            if let email = await AccountIdentity.email(provider: provider, configDir: account.configDir) {
                result.insert(email.lowercased())
            }
        }
        return result
    }

    private func accountRow(_ account: ExtraAccount) -> some View {
        HStack(spacing: 10) {
            ProviderIcon(source: .providerMark(account.provider))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                TextField(defaultName(for: account), text: nameBinding(for: account))
                    .textFieldStyle(.plain)
                    .disabled(emails[account.instanceID] == nil)
                Text(emails[account.instanceID] ?? account.configDir)
                    .font(.caption2)
                    .foregroundStyle(emails[account.instanceID] != nil ? .secondary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                container.accounts.remove(instanceID: account.instanceID)
                changedAccounts = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove Account")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private var addButton: some View {
        Button { isAdding = true } label: {
            Label("Add Account…", systemImage: "plus").frame(maxWidth: .infinity)
        }
        .glassButtonStyle()
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Provider")
                Spacer(minLength: 8)
                Picker("", selection: $newProvider) {
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(loginState == .loggingIn)
            }
            HStack(spacing: 10) {
                Text("Label")
                Spacer(minLength: 8)
                TextField("Work", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disabled(loginState == .loggingIn)
            }
            if case .failed(let message) = loginState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if loginState == .loggingIn {
                Text("Complete the login in your browser…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel") { resetForm() }
                    .glassButtonStyle()
                    .disabled(loginState == .loggingIn)
                Spacer()
                Button(action: logIn) {
                    if loginState == .loggingIn {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Logging In…")
                        }
                    } else {
                        Text("Log In")
                    }
                }
                .glassButtonStyle()
                .disabled(loginState == .loggingIn || newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private var relaunchNotice: some View {
        HStack(spacing: 8) {
            Text("Relaunch to apply account changes.")
                .font(.caption)
                .foregroundStyle(Theme.notice)
            Spacer()
            Button("Relaunch") { relaunch() }
                .glassButtonStyle()
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private func logIn() {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        let provider = newProvider
        let slot = Self.makeSlot()
        let dir = AccountLogin.defaultConfigDir(provider: provider, slot: slot)
        loginState = .loggingIn
        Task {
            do {
                try await AccountLogin.run(provider: provider, configDir: dir)
                // Reject a duplicate: logging the same account in twice causes token conflicts. The CLI
                // already wrote real credentials into `dir`, so remove that orphaned config on rejection.
                if let newEmail = await AccountIdentity.email(provider: provider, configDir: dir),
                   await existingEmails(forProvider: provider).contains(newEmail.lowercased()) {
                    try? FileManager.default.removeItem(atPath: dir)
                    loginState = .failed("\(newEmail) is already added — remove the existing one first.")
                    return
                }
                container.accounts.add(ExtraAccount(provider: provider, slot: slot, label: label, configDir: dir))
                changedAccounts = true
                resetForm()
                // The provider list is built at launch, and the popover has usually closed during the
                // browser login — relaunch so the new account loads without hunting for a prompt.
                relaunch()
            } catch {
                loginState = .failed(error.localizedDescription)
            }
        }
    }

    private func resetForm() {
        isAdding = false
        newLabel = ""
        loginState = .idle
    }

    private func relaunch() {
        AppControl.restart()
    }

    /// The card name for an account, bound to the names store by the account's (resolved) email so the
    /// name follows the account across the dashboard — including whichever copy is the current default.
    private func nameBinding(for account: ExtraAccount) -> Binding<String> {
        Binding(
            get: {
                guard let email = emails[account.instanceID] else { return "" }
                return container.accountNames.name(for: email) ?? ""
            },
            set: { newValue in
                guard let email = emails[account.instanceID] else { return }
                container.accountNames.setName(newValue, for: email)
            }
        )
    }

    private func defaultName(for account: ExtraAccount) -> String {
        "\(account.provider == "codex" ? "Codex" : "Claude") · \(account.label)"
    }

    private static func makeSlot() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
    }
}

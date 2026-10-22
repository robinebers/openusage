import AppKit
import SwiftUI

/// The Codex Accounts card in a Codex card's Customize detail: the logins OpenUsage signed in
/// itself, each with Sign In Again and Remove behind its row's menu, plus Add Account. A sign-in
/// runs the Codex CLI against a private home and hands off to the browser; while it runs, the Add
/// row becomes the progress row, with the sign-in link in case the browser stayed closed. A
/// successful change rebuilds the dashboard's
/// Codex cards in place and is confirmed by `CustomizeView` through the notice pill (the section
/// itself may be gone by then); failures stay in the card until dismissed.
struct CodexAccountsSection: View {
    @Environment(AppContainer.self) private var container
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var pendingRemoval: CodexManagedLogin?

    private var service: CodexManagedAccountService { container.codexAccounts }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Codex Accounts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(service.logins) { login in
                    loginRow(login)
                    Divider().padding(.horizontal, 12)
                }
                footerRow
            }
            .cardSurface()
        }
        .alert("Remove Codex Account?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { login in
            Button("Remove", role: .destructive) { service.remove(login) }
            Button("Cancel", role: .cancel) {}
        } message: { login in
            Text("Signs \(accountName(for: login)) out of OpenUsage and deletes its private Codex folder, including any sessions Codex ran there. Logins in Codex, xswap, or pi are not affected.")
        }
    }

    private func loginRow(_ login: CodexManagedLogin) -> some View {
        let renewing: Bool = {
            if case .signingIn(let id, _) = service.phase { return id == login.id }
            return false
        }()
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: login))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(for: login))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if renewing {
                MotionAwareProgressView(controlSize: .mini)
                    .accessibilityLabel("Signing In Again, \(accountName(for: login))")
            } else {
                actionsMenu(for: login)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    /// Both row actions behind one small menu, so a long email keeps the row's width.
    private func actionsMenu(for login: CodexManagedLogin) -> some View {
        Menu {
            Button("Sign In Again") { service.signInAgain(login) }
            Button("Remove…", role: .destructive) { pendingRemoval = login }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(service.isBusy)
        .accessibilityLabel("Actions for \(accountName(for: login))")
    }

    /// The row under the logins: Add Account while idle, and while a change runs it becomes the
    /// progress row instead of sitting disabled above one — one row, not three.
    @ViewBuilder
    private var footerRow: some View {
        switch service.phase {
        case .idle, .succeeded:
            addRow
        case .signingIn(_, let url):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    MotionAwareProgressView(controlSize: .mini)
                        .accessibilityHidden(true)
                    Text("Continue in your browser…")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Cancel") { service.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let url, let link = URL(string: url) {
                    // For a browser that stayed closed, or a different account: paste the link into a
                    // private window or another browser.
                    HStack(spacing: 6) {
                        Button("Open Sign-In Page") { NSWorkspace.shared.open(link) }
                        Text("·").foregroundStyle(.tertiary)
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        }
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)
        case .applying:
            HStack(spacing: 6) {
                MotionAwareProgressView(controlSize: .mini)
                    .accessibilityHidden(true)
                Text("Updating the Codex cards…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)
        case .failed(let message):
            addRow
            HStack(alignment: .top, spacing: 8) {
                Text(message)
                    .foregroundStyle(Theme.notice)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dismiss") { service.dismissMessage() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            Text(service.logins.isEmpty ? "Sign in to another ChatGPT account without changing your Codex login." : "Add another ChatGPT account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Add Account…") { service.addAccount() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(service.isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private func title(for login: CodexManagedLogin) -> String {
        login.identity?.email ?? login.identityKey
    }

    /// The sign-in date, plus the workspace only when another entry shares the email.
    private func subtitle(for login: CodexManagedLogin) -> String {
        let signedIn = "Signed in \(login.lastSignedInAt.formatted(date: .abbreviated, time: .omitted))"
        guard let identity = login.identity, sharesEmail(login) else { return signedIn }
        return "\(signedIn) · \(identity.workspaceLabel)"
    }

    /// How alerts and accessibility labels name the account: the email, with the workspace only
    /// when another entry shares it.
    private func accountName(for login: CodexManagedLogin) -> String {
        guard let identity = login.identity, sharesEmail(login) else { return title(for: login) }
        return "\(title(for: login)) (\(identity.workspaceLabel.lowercased()))"
    }

    private func sharesEmail(_ login: CodexManagedLogin) -> Bool {
        guard let email = login.identity?.email else { return false }
        return service.logins.contains { $0.id != login.id && $0.identity?.email == email }
    }
}

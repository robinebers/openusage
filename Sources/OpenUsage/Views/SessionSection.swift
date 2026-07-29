import SwiftUI

/// The per-provider session card shown in a provider's Customize detail when its credential is a
/// captured web session rather than an API key (currently Qwen Cloud). Mirrors `APIKeysSection`'s
/// shape: a status-dot row — red when no session is saved, green when one is — with Sign In / Sign
/// Out. Sign In opens the provider's sign-in window; on a captured session the card clears the
/// failure backoff and forces a refresh so the dashboard updates immediately.
struct SessionSection: View {
    let provider: any SessionManaging
    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    /// Live status, seeded on appear and re-read after each sign in/out so the dot stays truthful
    /// without re-reading files on every render.
    @State private var signedIn = false
    /// A sign-in window is open; the button reads "Signing In…" and is inert until it resolves.
    @State private var isSigningIn = false
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Cloud Session")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                sessionRow
                if let actionError {
                    Divider()
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(Theme.notice)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Rectangle().fill(.fill.quinary))
                }
            }
            .cardSurface()
            .clipShape(Theme.cardShape)
        }
        .onAppear { signedIn = provider.hasSession }
    }

    private var sessionRow: some View {
        HStack(spacing: 10) {
            ProviderIcon(source: provider.provider.icon)
                .frame(width: 18, height: 18)
            Text(provider.provider.displayName)
            Spacer(minLength: 8)
            statusDot
            if signedIn {
                Button("Sign Out", action: signOut)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(isSigningIn ? "Signing In…" : "Sign In", action: signIn)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSigningIn)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    /// Binary, like the API key card's: red without a session, green with one.
    private var statusDot: some View {
        let color = signedIn ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed)
        return Circle().fill(color).frame(width: 6, height: 6)
    }

    // MARK: - Actions

    private func signIn() {
        isSigningIn = true
        actionError = nil
        provider.beginSignIn { result in
            isSigningIn = false
            switch result {
            case .success:
                signedIn = true
                triggerRefresh()
            case .failure(let error):
                // Closing the window early is a no-op, not an error worth displaying.
                if (error as? QwenAuthError) != .signInCancelled {
                    actionError = error.localizedDescription
                }
            }
        }
    }

    private func signOut() {
        do {
            try provider.signOut()
            signedIn = false
            actionError = nil
            triggerRefresh()
        } catch {
            actionError = error.localizedDescription
            AppLog.error(.auth, "Qwen session sign-out failed: \(error.localizedDescription)")
        }
    }

    /// Clear any failure backoff so the wake refresh actually probes the provider, then force a
    /// refresh so the dashboard shows the new session's data immediately instead of waiting for the
    /// next 5-minute pass — same pattern the API Key card uses after a save.
    private func triggerRefresh() {
        let id = provider.provider.id
        dataStore.clearFailureBackoff(for: id)
        Task { await dataStore.refresh(providerID: id, force: true) }
    }
}

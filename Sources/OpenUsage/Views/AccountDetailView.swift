import SwiftUI

struct AccountDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    let providerID: String

    @State private var isConfirmingRemoval = false
    @State private var removalError: String?

    var body: some View {
        if let provider = layout.provider(id: providerID) {
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                if let host = provider.hubHost {
                    managedRow(host)
                } else {
                    if let field = container.accounts.account(cardID: providerID).flatMap(Self.replacedField) {
                        ReplaceKeyRow(field: field) { try await container.replaceKey($0, for: providerID) }
                    }
                    removeAccountRow(provider)
                    if let removalError {
                        ErrorText(removalError)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    private static func replacedField(_ account: Account) -> String? {
        switch account.authMethod {
        case .apiKey: "API Key"
        case .organizationToken: "Token"
        case .oauth: nil
        }
    }

    /// A hub's login is added, signed in, and removed on the hub, so its page offers none of that here.
    private func managedRow(_ host: String) -> some View {
        HStack(spacing: 8) {
            ProviderIcon(id: CLIProxyHub.markID, side: 16, inset: 0)
            Text("Managed by CLIProxyAPI at \(host)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, PanelMetrics.controlRowPadding)
        .cardSurface()
    }

    private func removeAccountRow(_ provider: Provider) -> some View {
        Button(role: .destructive) {
            isConfirmingRemoval = true
        } label: {
            Text("Remove Account…")
                .foregroundStyle(Color(nsColor: .systemRed))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, PanelMetrics.controlRowPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface()
        .confirmationDialog(
            "Remove \(provider.fullName)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) { removeAccount() }
        } message: {
            Text("Its sign-in is deleted from this Mac. You can add the account again at any time.")
        }
    }

    private func removeAccount() {
        guard let account = container.accounts.account(cardID: providerID) else { return }
        container.accounts.remove(account.id)
        if container.accounts.account(cardID: providerID) != nil {
            removalError = container.accounts.lastError ?? "The account could not be removed."
        } else {
            withAnimation(Motion.spring) { popover.customizeProviderID = nil }
        }
    }
}

/// Replaces a key in place: the new key is kept only once `commit` accepts it.
struct ReplaceKeyRow: View {
    let field: String
    let commit: @MainActor (String) async throws -> Void
    @State private var isEditing = false
    @State private var key = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing { editor } else { replaceButton }
        }
        .cardSurface()
    }

    private var replaceButton: some View {
        Button {
            isEditing = true
        } label: {
            Text("Replace \(field)…")
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, PanelMetrics.controlRowPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(field, text: $key, prompt: Text("New \(field)"))
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(save)
                .onExitCommand(perform: close)
                .onAppear { isFocused = true }
            if let errorMessage {
                ErrorText(errorMessage)
            }
            HStack {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", action: close)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .disabled(isSaving)
        .padding(12)
    }

    private var canSave: Bool {
        !isSaving && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await commit(key)
                close()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func close() {
        isEditing = false
        key = ""
        errorMessage = nil
    }
}

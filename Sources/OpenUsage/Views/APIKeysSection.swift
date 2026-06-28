import SwiftUI
import AppKit

/// Settings ▸ API Keys — the second card from the Option 2 decision in the `openrouter-api-key-ux`
/// canvas. Lists every provider that needs a user-supplied API key (`APIKeyManaging`), each row a
/// status dot + Edit/Add button. Expanding reveals the native macOS key field with a clear button
/// and an eye beside it: read-only by default, showing a muted source hint; the eye reveals the real
/// key; "Override With a Custom Key" flips the same field to editable for a new key; a leading clear
/// button clears a saved/override key.
///
/// Providers (the card above) stays pure enable toggles; this card owns key management. A saved key
/// writes to the config file the auth store already reads, and config > env — so "save" is also
/// "override the env key", and clearing a saved override falls back to the env key or to none.
/// After any change the card clears the provider's failure backoff and forces a refresh so the
/// dashboard updates immediately.
struct APIKeysSection: View {
    let providers: [any APIKeyManaging]
    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    /// The provider whose editor is expanded. One at a time — the 320pt popover can't hold two open
    /// editors comfortably, and the editor's transient state is scoped to this single provider.
    @State private var expandedID: String?
    /// Live status per provider, seeded on appear and re-read after each save/clear so the collapsed
    /// row's status dot stays truthful without re-reading files on every render.
    @State private var statusByID: [String: APIKeyStatus] = [:]

    // Transient editor state for the currently-expanded provider. Reset whenever a different provider
    // is expanded or a save/clear commits.
    @State private var revealDisplay = false
    @State private var revealInput = false
    @State private var overrideChecked = false
    @State private var input = ""
    @State private var revealedKey: String?
    @State private var actionError: String?

    private static let inputPlaceholder = "sk-or-v1-…"

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("API Keys")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                ForEach(providers, id: \.provider.id) { provider in
                    providerRow(provider)
                    if expandedID == provider.provider.id {
                        Divider()
                        editorBlock(provider)
                    }
                }
            }
            .cardSurface()
            // Clip the recessed editor block to the card's rounded corners so its flush rectangle
            // background can't poke out of the card's rounded bottom.
            .clipShape(Theme.cardShape)
        }
        .onAppear { seedStatuses() }
    }

    // MARK: - Rows

    private func providerRow(_ provider: any APIKeyManaging) -> some View {
        let id = provider.provider.id
        let status = statusByID[id] ?? .notSet
        let isOpen = expandedID == id
        return HStack(spacing: 10) {
            ProviderIcon(source: provider.provider.icon)
                .frame(width: 18, height: 18)
            Text(provider.provider.displayName)
            Spacer(minLength: 8)
            statusDot(status)
            Button(isOpen ? "Done" : (status == .notSet ? "Add" : "Edit")) {
                toggleExpand(provider)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    /// The dot is binary, never a palette: red when no key is set, green when a key is usable (from
    /// the environment, saved, or overriding the env). It's the row's only status signal.
    private func statusDot(_ status: APIKeyStatus) -> some View {
        let color = status == .notSet ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen)
        return Circle().fill(color).frame(width: 6, height: 6)
    }

    // MARK: - Editor

    @ViewBuilder
    private func editorBlock(_ provider: any APIKeyManaging) -> some View {
        let status = statusByID[provider.provider.id] ?? .notSet
        VStack(alignment: .leading, spacing: 8) {
            if status == .notSet {
                // No key anywhere: the field is editable from the start.
                keyField(provider, editable: true)
                primaryButton("Save", disabled: !hasInput) { save(provider) }
            } else if status == .fromEnvironment {
                // Env key, no custom key yet: read-only until "Override" is checked, then editable.
                keyField(provider, editable: overrideChecked)
                if overrideChecked {
                    HStack(spacing: 8) {
                        primaryButton("Save", disabled: !hasInput) { save(provider) }
                        ghostButton("Cancel") { overrideChecked = false; input = "" }
                    }
                } else {
                    Toggle("Override With a Custom Key", isOn: $overrideChecked)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            } else {
                // saved / overrideActive: a custom key is already set, so the override checkbox is
                // hidden. The field's clear (x) removes it — falling back to env (the checkbox
                // re-appears) or to none (the notSet editor takes over).
                keyField(provider, editable: false)
            }
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(.fill.quinary))
        .onChange(of: overrideChecked) { _, isOn in
            // Flipping into override mode starts a fresh entry; flipping back drops the draft.
            if isOn { input = ""; revealInput = false }
        }
    }

    /// The single field, in read-only or editable mode. Read-only shows a muted source hint (or the
    /// revealed key once the eye is clicked) and carries a leading clear button when a saved key can
    /// be cleared; editable binds to `input` for a new key.
    @ViewBuilder
    private func keyField(_ provider: any APIKeyManaging, editable: Bool) -> some View {
        let status = statusByID[provider.provider.id] ?? .notSet
        if editable {
            APIKeyField(
                text: $input,
                placeholder: Self.inputPlaceholder,
                readOnly: false,
                displayText: "",
                reveal: revealInput,
                onReveal: { revealInput.toggle() },
                onClear: nil
            )
        } else {
            let hint = sourceHint(provider)
            let display = revealDisplay ? (revealedKey ?? hint) : hint
            // Only a saved (config-file) key can be cleared here — an env-only key can't be deleted
            // from the app. Clearing an override falls back to the env key.
            let onClear: (() -> Void)? = (status == .saved || status == .overrideActive)
                ? { remove(provider) }
                : nil
            APIKeyField(
                text: .constant(""),
                placeholder: "",
                readOnly: true,
                displayText: display,
                reveal: revealDisplay,
                onReveal: { toggleRevealDisplay(provider) },
                onClear: onClear
            )
        }
    }

    /// The muted hint shown in the read-only field — the one piece of source info that survives the
    /// declutter, living inside the field instead of as a label beside it.
    private func sourceHint(_ provider: any APIKeyManaging) -> String {
        switch statusByID[provider.provider.id] ?? .notSet {
        case .fromEnvironment: "From Your Environment"
        case .saved: "Saved in App"
        case .overrideActive: "Custom Key"
        case .notSet: ""
        }
    }

    private var hasInput: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func primaryButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(disabled)
    }

    private func ghostButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .controlSize(.small)
    }

    // MARK: - Actions

    private func seedStatuses() {
        for provider in providers {
            statusByID[provider.provider.id] = provider.apiKeyStatus
        }
    }

    private func refreshStatus(_ provider: any APIKeyManaging) {
        statusByID[provider.provider.id] = provider.apiKeyStatus
    }

    private func toggleExpand(_ provider: any APIKeyManaging) {
        if expandedID == provider.provider.id {
            expandedID = nil
        } else {
            expandedID = provider.provider.id
            resetEditor()
            refreshStatus(provider)
        }
    }

    private func resetEditor() {
        revealDisplay = false
        revealInput = false
        overrideChecked = false
        input = ""
        revealedKey = nil
        actionError = nil
    }

    private func toggleRevealDisplay(_ provider: any APIKeyManaging) {
        revealDisplay.toggle()
        if revealDisplay { revealedKey = provider.currentAPIKey() }
    }

    private func save(_ provider: any APIKeyManaging) {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try provider.saveAPIKey(key)
            actionError = nil
            input = ""
            overrideChecked = false
            revealDisplay = false
            revealInput = false
            revealedKey = nil
            refreshStatus(provider)
            triggerRefresh(provider)
        } catch {
            actionError = error.localizedDescription
            AppLog.error(.auth, "API key save failed for \(provider.provider.id): \(error.localizedDescription)")
        }
    }

    private func remove(_ provider: any APIKeyManaging) {
        do {
            try provider.deleteAPIKey()
            actionError = nil
            overrideChecked = false
            input = ""
            revealDisplay = false
            revealInput = false
            revealedKey = nil
            refreshStatus(provider)
            triggerRefresh(provider)
        } catch {
            actionError = error.localizedDescription
            AppLog.error(.auth, "API key delete failed for \(provider.provider.id): \(error.localizedDescription)")
        }
    }

    /// Clear any failure backoff so the wake refresh actually probes the provider, then force a
    /// refresh so the dashboard shows the new key's data immediately instead of waiting for the next
    /// 5-minute pass. No-op for the refresh if the provider is disabled — the key is still saved.
    private func triggerRefresh(_ provider: any APIKeyManaging) {
        let id = provider.provider.id
        dataStore.clearFailureBackoff(for: id)
        Task { await dataStore.refresh(providerID: id, force: true) }
    }
}

/// The API-key input: the native macOS bordered text field with a leading clear button (optional)
/// and a trailing eye toggle right beside it. Read-only mode is a disabled native field showing a
/// source hint or the revealed key (genuinely non-editable); the eye + clear stay clickable because
/// they're siblings, not inside the disabled field. Editable mode binds to `text`, and the eye swaps
/// Secure/Text visibility. No custom background, border, or padding — just the system field.
private struct APIKeyField: View {
    @Binding var text: String
    var placeholder: String
    var readOnly: Bool
    var displayText: String
    var reveal: Bool
    var onReveal: () -> Void
    var onClear: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let onClear {
                fieldIcon("xmark.circle.fill", action: onClear, label: "Clear")
            }
            Group {
                if readOnly {
                    TextField(placeholder, text: .constant(displayText))
                        .disabled(true)
                } else if reveal {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            fieldIcon(reveal ? "eye.slash" : "eye", action: onReveal, label: reveal ? "Hide" : "Show")
        }
    }

    /// A small borderless inline icon button beside the field — the clear (x) and the eye.
    private func fieldIcon(_ symbol: String, action: @escaping () -> Void, label: String) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

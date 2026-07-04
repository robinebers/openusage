import SwiftUI

struct CodexAccountsSection: View {
    @Environment(AppContainer.self) private var container
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var renameDrafts: [String: String] = [:]

    var body: some View {
        @Bindable var oauth = container.codexOAuth
        let records = container.codexAccounts.settingsRecords()
        return VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Codex Accounts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                ForEach(records) { record in
                    accountRow(record)
                    if record.id != records.last?.id {
                        Divider()
                    }
                }
                Divider()
                actionBlock(status: oauth.status, waiting: oauth.isWaiting)
            }
            .cardSurface()
            .clipShape(Theme.cardShape)
        }
        .onAppear {
            for record in records {
                renameDrafts[record.identity] = record.displayName
            }
        }
    }

    private func accountRow(_ record: CodexAccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProviderIcon(source: .providerMark("codex"))
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayName)
                    Text(sourceLabel(record.source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if record.source == .managed {
                    Button("Remove") {
                        remove(record)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Hide") {
                        hide(record)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if record.source == .managed {
                HStack(spacing: 8) {
                    TextField("Account Name", text: Binding(
                        get: { renameDrafts[record.identity] ?? record.displayName },
                        set: { renameDrafts[record.identity] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        container.codexAccounts.rename(record, to: renameDrafts[record.identity] ?? "")
                        container.reloadCodexAccounts()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    @ViewBuilder
    private func actionBlock(status: CodexOAuthCoordinator.Status, waiting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(waiting ? "Waiting for Browser…" : "Add Codex Account") {
                    container.codexOAuth.start {
                        container.reloadCodexAccounts()
                        Task { await container.dataStore.refreshAll(force: true) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(waiting)
                if waiting {
                    Button("Cancel") {
                        container.codexOAuth.cancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            switch status {
            case .idle:
                EmptyView()
            case .waiting:
                Text("Finish signing in with ChatGPT in your browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
            case .succeeded:
                Text("Codex account added.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(.fill.quinary))
    }

    private func remove(_ record: CodexAccountRecord) {
        container.codexAccounts.removeManaged(record)
        container.reloadCodexAccounts(forgetRemoved: record.providerID)
    }

    private func hide(_ record: CodexAccountRecord) {
        container.codexAccounts.hideCLI(record)
        container.enablement.setEnabled(false, for: record.providerID)
        container.reloadCodexAccounts(forgetRemoved: record.providerID)
    }

    private func sourceLabel(_ source: CodexAccountRecord.Source) -> String {
        switch source {
        case .managed: "Signed in with OpenUsage"
        case .cliFile, .cliKeychain: "Imported from Codex CLI"
        }
    }
}

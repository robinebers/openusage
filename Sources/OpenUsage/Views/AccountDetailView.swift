import SwiftUI

struct AccountDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    @Environment(WidgetDataStore.self) private var dataStore
    let providerID: String
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let frameStore: ReorderFrameStore

    @State private var activeMetricID: String?
    @State private var isConfirmingRemoval = false
    @State private var removalError: String?

    var body: some View {
        if let provider = layout.provider(id: providerID) {
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                if let host = provider.hubHost {
                    metricsCard
                    infoRow(icon: CLIProxyHub.markID, "Managed by \(host)")
                } else {
                    if let problem = dataStore.problem(for: providerID) {
                        ProblemCard(message: problem)
                        if container.accounts.account(cardID: providerID)?.authMethod == .oauth {
                            signInAgainRow
                        }
                    }
                    metricsCard
                    if let domain = provider.domain {
                        infoRow(icon: provider.icon, "Signed in at \(domain)")
                    }
                    VStack(spacing: 0) {
                        if let field = container.accounts.account(cardID: providerID).flatMap(Self.replacedField) {
                            ReplaceKeyRow(field: field) { try await container.replaceKey($0, for: providerID) }
                        }
                        removeAccountRow(provider)
                    }
                    .cardSurface()
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

    @ViewBuilder
    private var metricsCard: some View {
        let metrics = layout.orderedSupportedMetrics(for: providerID)
        if !metrics.isEmpty {
            VStack(spacing: 0) {
                ForEach(metrics, id: \.id) { metric in
                    metricRow(metric)
                }
            }
            .cardSurface()
        }
    }

    private func metricRow(_ metric: WidgetDescriptor) -> some View {
        AccountMetricRow(
            title: metric.title,
            isShown: Binding(
                get: { layout.isMetricShown(metric.id) },
                set: { layout.setMetric(metric.id, shown: $0) }
            ),
            isPinned: Binding(
                get: { layout.isMetricPinned(metric.id) },
                set: { layout.setMetric(metric.id, pinned: $0) }
            ),
            grip: { ReorderGrip().highPriorityGesture(metricDragGesture(for: metric)) }
        )
        .opacity(activeMetricID == metric.id ? 0 : 1)
        .reorderFrame(id: metric.id, in: .named(reorderSpaceName))
    }

    private func metricDragGesture(for metric: WidgetDescriptor) -> some Gesture {
        reorderDragGesture(
            id: metric.id,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { value in
                ReorderLift.make(
                    id: metric.id,
                    preview: AnyView(
                        AccountMetricRow(
                            title: metric.title,
                            isShown: .constant(layout.isMetricShown(metric.id)),
                            isPinned: .constant(layout.isMetricPinned(metric.id))
                        ) { ReorderGrip() }
                            .liftedRowSurface()
                    ),
                    value: value,
                    frames: frameStore.frames
                )
            },
            orderedIDs: { layout.orderedSupportedMetrics(for: providerID).map(\.id) },
            reorder: { layout.reorderMetric(dragged: metric.id, target: $0, in: providerID) }
        )
    }

    private static func replacedField(_ account: Account) -> String? {
        switch account.authMethod {
        case .apiKey: "API Key"
        case .organizationToken: "Token"
        case .oauth: nil
        }
    }

    /// Where the account lives: a hub's login is added, signed in, and removed on the hub, so its page
    /// offers none of that here, and a Copilot enterprise account names the GHE.com domain it signs in at.
    private func infoRow(icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            ProviderIcon(id: icon, side: 16, inset: 0)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, PanelMetrics.controlRowPadding)
        .cardSurface()
    }

    private var signInAgainRow: some View {
        Button {
            popover.signingInAgainProviderID = providerID
            popover.isAddingAccount = true
        } label: {
            Text("Sign In Again…")
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, PanelMetrics.controlRowPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            withAnimation(Motion.navigation) { popover.customizeProviderID = nil }
        }
    }
}

/// Why an account or a hub needs the user, at the top of its page.
struct ProblemCard: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.notice)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface()
    }
}

struct AccountMetricRow<Grip: View>: View {
    let title: String
    @Binding var isShown: Bool
    @Binding var isPinned: Bool
    @ViewBuilder var grip: Grip

    var body: some View {
        HStack(spacing: 10) {
            grip
            Text(title)
            Spacer(minLength: 8)
            Button { isPinned.toggle() } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isPinned ? .secondary : .tertiary)
                    .frame(width: 16, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isShown)
            .accessibilityLabel(isPinned ? "Unpin \(title)" : "Pin \(title)")
            Toggle(title, isOn: $isShown)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, PanelMetrics.controlRowPadding)
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
        if isEditing { editor } else { replaceButton }
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

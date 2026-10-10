import AppKit
import SwiftUI

struct FirstLaunchWelcomeView: View {
    @Bindable var setup: FirstLaunchSetup
    let finish: (Set<String>) -> Void
    @State private var connectionTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Welcome to OpenUsage")
                    .font(.system(size: 27, weight: .semibold))
                Text("Choose the tools you want to follow. We'll use the sign-ins already on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 28)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Your Providers").font(.headline)
                    Spacer()
                    if setup.isDetecting {
                        ProgressView().controlSize(.small)
                        Text("Looking for sign-ins…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(setup.showAll ? "Show Detected" : "Show All") { setup.showAll.toggle() }
                            .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    VStack(spacing: 0) {
                        if !setup.isDetecting, setup.visibleChoices.isEmpty {
                            Text("No sign-ins found yet. Choose Show All to add a provider, or set up later.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(24)
                        }
                        ForEach(setup.visibleChoices) { choice in
                            providerRow(choice)
                            if choice.id != setup.visibleChoices.last?.id {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 28)

            GroupBox {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Access to Your Saved Sign-Ins")
                            .font(.callout.weight(.semibold))
                        Text("Connecting may open macOS permission dialogs for your selected providers. Choose Always Allow to keep background updates working.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)

            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 12) { actionButtons }
                    .padding(20)
            } else {
                actionButtons.padding(20)
            }

        }
        .frame(width: 520, height: 650)
        .onDisappear { connectionTask?.cancel() }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Skip for Now") { finish([]) }
                .onboardingSecondaryAction()
                .disabled(setup.isConnecting)
            Spacer()
            if setup.hasAttemptedConnection, setup.hasFailures {
                Button("Retry") { connect() }
                    .onboardingSecondaryAction()
                    .disabled(setup.isConnecting)
            }
            Button(primaryActionTitle) {
                if setup.hasAttemptedConnection { finish(setup.connectedIDs) } else { connect() }
            }
            .onboardingPrimaryAction()
            .keyboardShortcut(.defaultAction)
            .disabled(setup.isDetecting || setup.isConnecting || (!setup.hasAttemptedConnection && setup.selectedIDs.isEmpty))
        }
        .controlSize(.large)
    }

    private var primaryActionTitle: String {
        if setup.isConnecting { return "Checking…" }
        return setup.hasAttemptedConnection ? "Open Dashboard" : "Connect Selected"
    }

    private func connect() {
        connectionTask = Task { await setup.connectSelected() }
    }

    private func providerRow(_ choice: FirstLaunchSetup.Choice) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { setup.selectedIDs.contains(choice.id) },
                set: { selected in
                    if selected { setup.selectedIDs.insert(choice.id) }
                    else { setup.selectedIDs.remove(choice.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(choice.provider.displayName)
            .frame(width: 18)
            ProviderIcon(source: choice.provider.icon).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.provider.displayName).font(.body.weight(.medium))
                Text(status(choice)).font(.caption)
                    .foregroundStyle(choice.error == nil ? Color.secondary
                                     : choice.usageUnavailable ? Color.orange : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if choice.connecting {
                ProgressView().controlSize(.small)
            } else if choice.usageUnavailable {
                Image(systemName: "clock").foregroundStyle(.secondary)
            } else if choice.error != nil {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Needs Attention")
            } else if choice.connected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .disabled(setup.isConnecting || setup.hasAttemptedConnection)
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func status(_ choice: FirstLaunchSetup.Choice) -> String {
        if choice.connecting { return "Checking…" }
        if let error = choice.error { return error }
        if choice.connected { return "Enabled" }
        if choice.needsAccess { return "Needs macOS permissions" }
        return choice.detected ? "Sign-In Detected" : "Set Up or Sign In First"
    }
}

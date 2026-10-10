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
                Text("Your AI usage, together in the menu bar.")
                    .foregroundStyle(.secondary)
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
                .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.07), lineWidth: 1))
            }
            .padding(.horizontal, 28)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock").padding(.top, 2)
                Text("When you connect, macOS may ask to access saved sign-ins. Only your selected providers will be requested, one at a time. Choose Always Allow in macOS for background updates.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 30).padding(.vertical, 18)

            Divider()
            HStack {
                Button("Skip for Now") { finish([]) }
                    .disabled(setup.isConnecting)
                Spacer()
                if setup.hasAttemptedConnection, setup.hasFailures {
                    Button("Retry Failed") { connect() }.disabled(setup.isConnecting)
                }
                Button(setup.hasAttemptedConnection && !setup.isConnecting ? "Open Dashboard" : "Connect Selected") {
                    if setup.hasAttemptedConnection { finish(setup.connectedIDs) } else { connect() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(setup.isDetecting || setup.isConnecting || (!setup.hasAttemptedConnection && setup.selectedIDs.isEmpty))
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 520, height: 650)
        .onDisappear { connectionTask?.cancel() }
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
                    .foregroundStyle(choice.error == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if choice.connecting {
                ProgressView().controlSize(.small)
            } else if choice.connected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .disabled(setup.isConnecting || setup.hasAttemptedConnection)
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func status(_ choice: FirstLaunchSetup.Choice) -> String {
        if choice.connecting { return "Connecting…" }
        if choice.connected { return "Connected" }
        if let error = choice.error { return error }
        if choice.needsAccess { return "Needs macOS permissions" }
        return choice.detected ? "Sign-In Detected" : "Set Up or Sign In First"
    }
}

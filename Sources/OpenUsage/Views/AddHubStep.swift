import SwiftUI

/// Connects a CLIProxyAPI hub by its address and management key. There is no login checklist: the hub
/// decides which logins exist, and each supported one appears as an account once the hub answers.
struct HubConnectStep: View {
    @Bindable var flow: AddAccountFlow
    let cancel: () -> Void

    var body: some View {
        SheetHeader(
            provider: nil,
            icon: CLIProxyHub.markID,
            title: "Connect CLIProxyAPI",
            message: "Enter your CLIProxyAPI server’s address and management key. Its Claude, ChatGPT, Antigravity, Devin, and Grok logins appear as accounts. The key is stored in your Keychain."
        )
        Form {
            Section {
                TextField("URL", text: $flow.hubURL, prompt: Text("https://hub.example.com"))
                    .onSubmit { flow.connect() }
                SecureField("Management Key", text: $flow.apiKey, prompt: Text("Required"))
                    .onSubmit { flow.connect() }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The hub needs remote management turned on. OpenUsage uses https unless you type http://, which works only for this Mac or your local network.")
                        .foregroundStyle(.secondary)
                    if flow.hubURL.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://") {
                        Label("Over http, the management key crosses your network unencrypted.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.notice)
                    }
                    if let errorMessage = flow.errorMessage {
                        ErrorText(errorMessage)
                    }
                }
                .font(.footnote)
            }
        }
        .inlineGroupedForm()
        .disabled(flow.isWorking)
        SheetButtons(
            secondary: SheetAction(title: "Cancel", shortcut: .cancelAction, action: cancel),
            primary: SheetAction(title: flow.isWorking ? "Connecting…" : "Connect", isDisabled: !flow.canConnectHub) { flow.connect() }
        )
        .padding(.bottom, 20)
    }
}

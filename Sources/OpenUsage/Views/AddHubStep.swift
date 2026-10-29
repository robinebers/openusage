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
            message: "Enter your CLIProxyAPI server’s address and management key. Its Claude and ChatGPT logins appear as accounts. The key is stored in your Keychain."
        )
        Form {
            Section {
                TextField("URL", text: $flow.hubURL, prompt: Text("http://192.168.1.20:8317"))
                    .onSubmit { flow.connect() }
                SecureField("Management Key", text: $flow.apiKey, prompt: Text("Required"))
                    .onSubmit { flow.connect() }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The hub needs remote management turned on. Use https, an IP address, or a .local name.")
                        .foregroundStyle(.secondary)
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

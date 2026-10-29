import AppKit
import SwiftUI

struct AddAccountSheet: View {
    @State private var flow: AddAccountFlow
    @Environment(\.dismiss) private var dismiss

    init(flow: AddAccountFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if flow.isConnectingHub {
                HubConnectStep(flow: flow, cancel: { flow.back() })
            } else if let provider = flow.provider {
                switch flow.method {
                case nil: MethodChoiceStep(flow: flow, provider: provider, cancel: { flow.back() })
                case .oauth: BrowserSignInStep(flow: flow, provider: provider, cancel: { flow.back() })
                case .apiKey(let keyPage): APIKeyStep(flow: flow, provider: provider, keyPage: keyPage, cancel: { flow.back() })
                case .organizationToken: OrganizationTokenStep(flow: flow, provider: provider, cancel: { flow.back() })
                }
            } else {
                ProviderChoiceStep(flow: flow, cancel: { dismiss() })
            }
        }
        .frame(width: 300)
        // The browser the sign-in opens takes the keyboard, and AppKit then draws the sheet's controls
        // inactive: a grey default button. The sheet belongs to a menu-bar panel, where that state
        // means nothing, so its controls always draw active and the primary button keeps its accent.
        .environment(\.appearsActive, true)
        // The popover panel takes keys without activating the app, but this sheet is an ordinary
        // window: without activation its fields never receive typing. A process that may not be
        // activated (the test suite) has nothing to gain and would take the keyboard from its owner.
        .onAppear {
            if NSApp.activationPolicy() != .prohibited { NSApp.activate(ignoringOtherApps: true) }
        }
        .onDisappear { flow.cancel() }
        .onChange(of: flow.isFinished) { _, isFinished in
            if isFinished { dismiss() }
        }
    }
}

/// A row of the provider list: a provider to sign in to, or a CLIProxyAPI hub whose logins arrive as
/// accounts of their own providers.
private enum AddAccountChoice: Hashable {
    case provider(ProviderKind)
    case cliproxyHub
}

private struct ProviderChoiceStep: View {
    @Bindable var flow: AddAccountFlow
    let cancel: () -> Void
    @State private var isHubSelected = false

    var body: some View {
        SheetHeader(provider: nil, title: "Add Account", message: "Choose a provider to sign in to.")
        ChoiceList(
            items: ProviderKind.allCases.map(AddAccountChoice.provider) + [.cliproxyHub],
            selection: selection,
            choose: { choice in
                switch choice {
                case .provider(let kind): flow.choose(kind)
                case .cliproxyHub: flow.chooseHub()
                }
            }
        ) { choice in
            switch choice {
            case .provider(let provider):
                ProviderIcon(id: provider.rawValue, side: 20, inset: 0.06)
                Text(provider.displayName)
            case .cliproxyHub:
                ProviderIcon(id: CLIProxyHub.markID, side: 20, inset: 0.06)
                Text("CLIProxyAPI")
            }
        }
        CancelRow(cancel: cancel)
    }

    private var selection: Binding<AddAccountChoice?> {
        Binding(
            get: { isHubSelected ? .cliproxyHub : flow.selection.map(AddAccountChoice.provider) },
            set: { choice in
                isHubSelected = choice == .cliproxyHub
                if case .provider(let kind) = choice { flow.selection = kind } else { flow.selection = nil }
            }
        )
    }
}

private struct MethodChoiceStep: View {
    let flow: AddAccountFlow
    let provider: ProviderKind
    let cancel: () -> Void
    @State private var selection: ProviderAuthMethod?

    var body: some View {
        SheetHeader(
            provider: provider,
            title: "Add \(provider.displayName)",
            message: "Sign in to your own seat, or add your organization’s billing with a token."
        )
        ChoiceList(items: provider.authMethods, selection: $selection, choose: { flow.choose($0) }) { method in
            Text(method == .organizationToken ? "Organization Billing" : "Sign In with GitHub")
        }
        CancelRow(cancel: cancel)
    }
}

/// A provider's or a sign-in method's list: an arrow key moves the selection, and a click or Return
/// chooses.
private struct ChoiceList<Item: Hashable, Label: View>: View {
    let items: [Item]
    @Binding var selection: Item?
    let choose: (Item) -> Void
    @ViewBuilder let label: (Item) -> Label
    @FocusState private var isFocused: Bool

    var body: some View {
        List(items, id: \.self, selection: $selection) { item in
            HStack(spacing: 10) {
                label(item)
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
            .onTapGesture { choose(item) }
            .listItemTint(.monochrome)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .background(Theme.cardFill, in: .rect(cornerRadius: 10))
        .frame(height: CGFloat(items.count) * 28 + 20)
        .padding(.horizontal, 20)
        .focused($isFocused)
        .contextMenu(forSelectionType: Item.self, menu: { _ in }, primaryAction: { items in
            if let item = items.first { choose(item) }
        })
        .onAppear { isFocused = true }
    }
}

private struct CancelRow: View {
    let cancel: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }
}

private struct BrowserSignInStep: View {
    @Bindable var flow: AddAccountFlow
    let provider: ProviderKind
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(provider: provider, title: "Sign In to \(provider.displayName)", message: message)
            if case .deviceCode(let userCode, _) = flow.prompt {
                DeviceCodeBox(code: userCode)
                    .padding(.horizontal, 20)
            }
            if flow.errorMessage == nil, let pasteField {
                pastedCodeForm(pasteField)
            }
            SheetButtons(secondary: secondaryAction, primary: primaryAction)
            status
                .padding(.top, 12)
                .padding([.horizontal, .bottom], 20)
        }
        .overlay(alignment: .topTrailing) {
            CloseButton(action: cancel)
        }
    }

    private var message: String {
        switch flow.prompt {
        case .deviceCode: "Open the verification page in your browser and enter this code."
        case .browserToken: "Continue in your browser, then paste the token it shows here."
        case .browser, nil: "Continue in your browser. This sheet closes when you’re signed in."
        }
    }

    private var pasteField: (name: String, footer: String?)? {
        switch flow.prompt {
        case .browser(_, acceptsPastedCode: true): ("Code", "Paste the code here if your browser shows one.")
        case .browserToken: ("Token", nil)
        case .browser, .deviceCode, nil: nil
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            if let errorMessage = flow.errorMessage {
                ErrorText(errorMessage, alignment: .center)
            } else {
                if flow.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(statusText)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
    }

    private var statusText: String {
        if flow.prompt == nil { return "Preparing sign-in…" }
        return flow.isCodeSubmitted ? "Signing in…" : "Waiting for your browser…"
    }

    private func pastedCodeForm(_ field: (name: String, footer: String?)) -> some View {
        Form {
            Section {
                TextField(field.name, text: $flow.pastedCode, prompt: Text("Paste \(field.name.lowercased())"))
                    .onSubmit { flow.submitCode() }
                    .disabled(flow.isCodeSubmitted)
            } footer: {
                if let footer = field.footer {
                    Text(footer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .inlineGroupedForm()
    }

    private var secondaryAction: SheetAction {
        switch flow.prompt {
        case .browser(let url, _), .browserToken(let url): SheetAction(title: "Copy Link") { copy(url.absoluteString) }
        case .deviceCode(let userCode, _): SheetAction(title: "Copy Code") { copy(userCode) }
        case nil: SheetAction(title: "Copy Link", isDisabled: true) {}
        }
    }

    private var primaryAction: SheetAction {
        if flow.errorMessage != nil {
            return SheetAction(title: "Try Again") { flow.signIn() }
        }
        if flow.hasPastedCode {
            return SheetAction(title: "Continue", isDisabled: !flow.canSubmitCode) { flow.submitCode() }
        }
        return SheetAction(title: "Open Browser", isDisabled: flow.prompt == nil) { flow.openBrowser() }
    }
}

private struct APIKeyStep: View {
    @Bindable var flow: AddAccountFlow
    let provider: ProviderKind
    let keyPage: URL
    let cancel: () -> Void

    var body: some View {
        SheetHeader(
            provider: provider,
            title: "Add \(provider.displayName)",
            message: "Enter an API key from your \(provider.displayName) account. It’s stored in your Keychain.",
            link: Link("Get Your API Key", destination: keyPage)
        )
        Form {
            Section {
                SecureField("API Key", text: $flow.apiKey, prompt: Text("Required"))
                    .onSubmit { flow.addKey() }
                TextField("Name", text: $flow.accountName, prompt: Text(provider.displayName))
                    .onSubmit { flow.addKey() }
            } footer: {
                if let errorMessage = flow.errorMessage {
                    ErrorText(errorMessage)
                }
            }
        }
        .inlineGroupedForm()
        SheetButtons(
            secondary: SheetAction(title: "Cancel", shortcut: .cancelAction, action: cancel),
            primary: SheetAction(title: "Add Account", isDisabled: !flow.canAddKey) { flow.addKey() }
        )
        .padding(.bottom, 20)
    }
}

private struct OrganizationTokenStep: View {
    @Bindable var flow: AddAccountFlow
    let provider: ProviderKind
    let cancel: () -> Void

    var body: some View {
        SheetHeader(
            provider: provider,
            title: "Add \(provider.displayName)",
            message: "Enter your organization and a token that can read its billing. It’s stored in your Keychain."
        )
        Form {
            Section {
                TextField("Organization", text: $flow.organization, prompt: Text("Required"))
                    .onSubmit { flow.addKey() }
                SecureField("Token", text: $flow.apiKey, prompt: Text("Required"))
                    .onSubmit { flow.addKey() }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shows your organization’s Copilot credits and spend. Use a personal access token from an organization owner or billing manager: fine-grained, with Organization permissions → Administration → Read-only.")
                        .foregroundStyle(.secondary)
                    Link("Create a Token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    if let errorMessage = flow.errorMessage {
                        ErrorText(errorMessage)
                    }
                }
                .font(.footnote)
            }
        }
        .inlineGroupedForm()
        SheetButtons(
            secondary: SheetAction(title: "Cancel", shortcut: .cancelAction, action: cancel),
            primary: SheetAction(title: "Add Account", isDisabled: !flow.canAddKey) { flow.addKey() }
        )
        .padding(.bottom, 20)
    }
}

struct SheetHeader: View {
    let provider: ProviderKind?
    var icon: String?
    let title: String
    let message: String
    var link: Link<Text>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let icon = icon ?? provider?.rawValue {
                ProviderIcon(id: icon, side: 32, inset: 0.04)
                    .padding(.bottom, 8)
            }
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let link {
                link
                    .font(.subheadline)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 14)
    }
}

struct SheetAction {
    let title: String
    var isDisabled = false
    var shortcut: KeyboardShortcut?
    let action: () -> Void
}

struct SheetButtons: View {
    let secondary: SheetAction
    let primary: SheetAction

    var body: some View {
        HStack {
            button(secondary, shortcut: secondary.shortcut)
                .buttonStyle(.bordered)
            button(primary, shortcut: primary.shortcut ?? .defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding([.horizontal, .top], 20)
    }

    private func button(_ action: SheetAction, shortcut: KeyboardShortcut?) -> some View {
        Button(action: action.action) {
            Text(action.title).frame(maxWidth: .infinity)
        }
        .keyboardShortcut(shortcut)
        .disabled(action.isDisabled)
    }
}

/// The close button where a macOS panel keeps one, in the top-right corner: SF Symbols'
/// xmark.circle.fill drawn hierarchically, the glyph system search fields and banners clear and
/// close with, since SwiftUI's own `Button(role: .close)` needs macOS 26. Escape presses it.
private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Cancel")
        .padding(14)
    }
}

private struct DeviceCodeBox: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(.title2, design: .monospaced).weight(.semibold))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.cardFill, in: .rect(cornerRadius: 10))
    }
}

struct ErrorText: View {
    let message: String
    var alignment: Alignment = .leading

    init(_ message: String, alignment: Alignment = .leading) {
        self.message = message
        self.alignment = alignment
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

@MainActor
private func copy(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}

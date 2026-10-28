import AppKit
import SwiftUI

/// Adds an account: choose a provider, then finish its browser, device-code, or API-key sign-in.
/// Opened as a sheet on the popover from the Accounts list's + and the empty dashboard.
struct AddAccountSheet: View {
    @State private var flow: AddAccountFlow
    @Environment(\.dismiss) private var dismiss

    init(flow: AddAccountFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let provider = flow.provider {
                if case .apiKey(let keyPage) = provider.authMethod {
                    APIKeyStep(flow: flow, provider: provider, keyPage: keyPage, cancel: { flow.back() })
                } else {
                    BrowserSignInStep(flow: flow, provider: provider, cancel: { flow.back() })
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

/// The provider list, like Internet Accounts' Add Account: one click on a provider goes straight to
/// its sign-in. The arrow keys move the selection and Return chooses it.
private struct ProviderChoiceStep: View {
    @Bindable var flow: AddAccountFlow
    let cancel: () -> Void
    @FocusState private var isListFocused: Bool

    var body: some View {
        SheetHeader(provider: nil, title: "Add Account", message: "Choose a provider to sign in to.")
        List(ProviderKind.allCases, id: \.self, selection: $flow.selection) { provider in
            HStack(spacing: 10) {
                ProviderIcon(id: provider.rawValue, side: 20, inset: 0.06)
                Text(provider.displayName)
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
            .onTapGesture { flow.choose(provider) }
            .listItemTint(.monochrome)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .background(Theme.cardFill, in: .rect(cornerRadius: 10))
        .frame(height: CGFloat(ProviderKind.allCases.count) * 28 + 20)
        .padding(.horizontal, 20)
        .focused($isListFocused)
        .contextMenu(forSelectionType: ProviderKind.self, menu: { _ in }, primaryAction: { providers in
            if let provider = providers.first { flow.choose(provider) }
        })
        .onAppear { isListFocused = true }
        HStack {
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }
}

/// The browser and device-code steps share one layout: the header, the code the user needs (a
/// box to read from, or a field to paste into), two equal buttons to copy and to open the browser,
/// and the sign-in's state centred under them. The browser sign-in already opened its page when
/// the step appeared, so the status line is true from the start.
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
            if flow.errorMessage == nil, case .browser(_, acceptsPastedCode: true) = flow.prompt {
                pastedCodeForm
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
        case .browser, nil: "Continue in your browser. This sheet closes when you’re signed in."
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

    private var pastedCodeForm: some View {
        Form {
            Section {
                TextField("Code", text: $flow.pastedCode, prompt: Text("Paste code"))
                    .onSubmit { flow.submitCode() }
                    .disabled(flow.isCodeSubmitted)
            } footer: {
                Text("Paste the code here if your browser shows one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .inlineGroupedForm()
    }

    private var secondaryAction: SheetAction {
        switch flow.prompt {
        case .browser(let url, _): SheetAction(title: "Copy Link") { copy(url.absoluteString) }
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

/// The title block every step opens with, left-aligned like a macOS alert: the provider's mark
/// once one is chosen, a bold title, and one line of guidance.
private struct SheetHeader: View {
    let provider: ProviderKind?
    let title: String
    let message: String
    var link: Link<Text>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let provider {
                ProviderIcon(id: provider.rawValue, side: 32, inset: 0.04)
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

private struct SheetAction {
    let title: String
    var isDisabled = false
    var shortcut: KeyboardShortcut?
    let action: () -> Void
}

/// Two buttons, each half the sheet's width; the primary one is prominent and the default, so Return
/// presses it.
private struct SheetButtons: View {
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

private struct ErrorText: View {
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

private extension View {
    /// A grouped form laid out inline in the sheet: sized to its rows instead of scrolling, and
    /// without the extra vertical margin the form adds around itself when it fills a window.
    func inlineGroupedForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, -16)
    }
}

@MainActor
private func copy(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}

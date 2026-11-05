import AppKit
import Foundation
import Observation

/// A row of the provider list: a provider to sign in to, or a CLIProxyAPI hub whose logins arrive as
/// accounts of their own providers.
enum AddAccountChoice: Hashable {
    case provider(ProviderKind)
    case cliproxyHub

    static var all: [AddAccountChoice] {
        ProviderKind.allCases.map(AddAccountChoice.provider) + (CLIProxyHub.isEnabled ? [.cliproxyHub] : [])
    }
}

@MainActor
@Observable
final class AddAccountFlow {
    var selection: AddAccountChoice?
    var apiKey = "" {
        didSet { if isConnectingHub, apiKey != oldValue { errorMessage = nil } }
    }
    var accountName = ""
    var pastedCode = ""
    var organization = ""
    /// The address typed into Copilot's Domain step.
    var domain = "" {
        didSet { if isEnteringDomain, domain != oldValue { errorMessage = nil } }
    }
    var hubURL = "" {
        didSet { if hubURL != oldValue { errorMessage = nil } }
    }
    private(set) var isConnectingHub = false
    private(set) var provider: ProviderKind?
    private(set) var method: ProviderAuthMethod?
    /// Where a Copilot sign-in goes, once its Domain step is done or the account being signed in again saved it.
    private(set) var gitHubDomain: GitHubDomain?
    private(set) var prompt: LoginPrompt?
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var isFinished = false

    private let store: AccountStore
    private let openURL: (URL) -> Void
    private let login: (ProviderKind, ProviderAuthMethod, String, GitHubDomain) -> any ProviderLogin
    private let connectHub: @MainActor (String, String) async throws -> Void
    private let replaceCredential: @MainActor (AccountCredential, String) async throws -> Void
    private let accountSignedInAgain: Account?
    private var task: Task<Void, Never>?
    private var codeInput: AsyncStream<String>.Continuation?

    var isSigningInAgain: Bool { accountSignedInAgain != nil }

    init(
        store: AccountStore,
        openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        login: @escaping (ProviderKind, ProviderAuthMethod, String, GitHubDomain) -> any ProviderLogin = ProviderLoginCatalog.login(for:method:organization:domain:),
        connectHub: @escaping @MainActor (String, String) async throws -> Void = { _, _ in },
        replaceCredential: @escaping @MainActor (AccountCredential, String) async throws -> Void = { _, _ in },
        signingInAgainTo account: Account? = nil
    ) {
        self.store = store
        self.openURL = openURL
        self.login = login
        self.connectHub = connectHub
        self.replaceCredential = replaceCredential
        accountSignedInAgain = account
        if let account {
            selection = .provider(account.kind)
            provider = account.kind
            method = account.authMethod
            gitHubDomain = GitHubDomain(saved: account.domain)
        }
    }

    var canAddKey: Bool {
        !apiKey.trimmed.isEmpty && !isWorking && (method != .organizationToken || !organization.trimmed.isEmpty)
    }
    var canConnectHub: Bool { !hubURL.trimmed.isEmpty && !apiKey.trimmed.isEmpty && !isWorking }
    var hasPastedCode: Bool { !pastedCode.trimmed.isEmpty }
    var canSubmitCode: Bool { hasPastedCode && codeInput != nil }
    var isCodeSubmitted: Bool { isWorking && prompt != nil && codeInput == nil }
    /// Copilot's own sign-in first asks for the domain: blank for github.com, or a GHE.com address.
    var isEnteringDomain: Bool { provider == .copilot && method == .oauth && gitHubDomain == nil }
    var canChangeDomain: Bool { provider == .copilot && method == .oauth && !isSigningInAgain }

    func choose(_ kind: ProviderKind) {
        selection = .provider(kind)
        provider = kind
        if kind.authMethods.count == 1 { choose(kind.authMethods[0]) }
    }

    func choose(_ method: ProviderAuthMethod) {
        self.method = method
        if method == .oauth, !isEnteringDomain { signIn() }
    }

    func continueToSignIn() {
        guard let parsed = GitHubDomain(parsing: domain) else {
            AppLog.warn(LogTag.auth("copilot"), "the entered domain is not a GHE.com address")
            errorMessage = GitHubDomain.invalidMessage
            return
        }
        errorMessage = nil
        gitHubDomain = parsed
        signIn()
    }

    /// Back to the Domain step, keeping what was typed.
    func changeDomain() {
        gitHubDomain = nil
        errorMessage = nil
    }

    func chooseHub() {
        selection = .cliproxyHub
        isConnectingHub = true
    }

    /// Connects a CLIProxyAPI hub; its logins arrive as accounts, so the sheet closes once it answers.
    func connect() {
        guard isConnectingHub, canConnectHub else { return }
        task?.cancel()
        errorMessage = nil
        isWorking = true
        let (url, key) = (hubURL, apiKey)
        task = Task {
            do {
                try await connectHub(url, key)
                guard !Task.isCancelled else { return }
                isWorking = false
                isFinished = true
            } catch {
                guard !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
    }

    /// Starts once the sheet shows: creating a flow must not open a browser.
    func startSigningInAgain() {
        guard isSigningInAgain, prompt == nil, !isWorking else { return }
        signIn()
    }

    func signIn() {
        guard let provider, let method else { return }
        let (input, continuation) = AsyncStream.makeStream(of: String.self)
        codeInput = continuation
        pastedCode = ""
        run(provider, method, input: input)
    }

    func openBrowser() {
        switch prompt {
        case .browser(let url, _), .browserToken(let url): openURL(url)
        case .deviceCode(_, let url): openURL(url)
        case nil: break
        }
    }

    func submitCode() {
        guard canSubmitCode else { return }
        codeInput?.yield(pastedCode)
        codeInput?.finish()
        codeInput = nil
    }

    func addKey() {
        guard let provider, let method, canAddKey else { return }
        let (input, continuation) = AsyncStream.makeStream(of: String.self)
        continuation.yield(apiKey)
        continuation.finish()
        run(provider, method, input: input)
    }

    func back() {
        cancel()
        provider = nil
        isConnectingHub = false
        hubURL = ""
        method = nil
        gitHubDomain = nil
        prompt = nil
        errorMessage = nil
        isWorking = false
        apiKey = ""
        accountName = ""
        organization = ""
        domain = ""
        pastedCode = ""
    }

    func cancel() {
        task?.cancel()
        task = nil
        codeInput?.finish()
        codeInput = nil
    }

    private func run(_ kind: ProviderKind, _ method: ProviderAuthMethod, input: AsyncStream<String>) {
        task?.cancel()
        prompt = nil
        errorMessage = nil
        isWorking = true
        let organization = method == .organizationToken ? self.organization.trimmed : nil
        let gitHubDomain = gitHubDomain
        let login = login(kind, method, organization ?? "", gitHubDomain ?? .github)
        task = Task {
            do {
                let result = try await login.login(
                    prompt: { prompt in await self.show(prompt) },
                    pastedCode: input
                )
                guard !Task.isCancelled else { return }
                if let accountSignedInAgain {
                    try await replaceCredential(result.credential, accountSignedInAgain.cardID)
                    guard !Task.isCancelled else { return }
                    finish()
                } else {
                    try save(result, for: kind, organization: organization, domain: gitHubDomain?.saved)
                }
            } catch {
                guard !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func show(_ prompt: LoginPrompt) {
        guard !Task.isCancelled else { return }
        self.prompt = prompt
        switch prompt {
        case .browser(let url, _), .browserToken(let url): openURL(url)
        case .deviceCode: break
        }
    }

    private func save(
        _ result: (label: String, credential: AccountCredential), for kind: ProviderKind, organization: String?, domain: String?
    ) throws {
        try store.checkForDuplicate(result.credential, kind: kind, organization: organization)
        let name = accountName.trimmed
        let account = store.add(
            kind: kind, label: name.isEmpty ? result.label : name, organization: organization, domain: domain,
            credential: result.credential
        )
        guard store.accounts.contains(where: { $0.id == account.id }) else {
            return fail(store.lastError ?? "The account could not be saved.")
        }
        finish()
    }

    private func finish() {
        codeInput?.finish()
        codeInput = nil
        isWorking = false
        isFinished = true
    }

    private func fail(_ message: String) {
        codeInput?.finish()
        codeInput = nil
        prompt = nil
        isWorking = false
        errorMessage = message
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

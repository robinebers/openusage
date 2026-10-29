import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AddAccountFlow {
    var selection: ProviderKind?
    var apiKey = ""
    var accountName = ""
    var pastedCode = ""
    var organization = ""
    private(set) var provider: ProviderKind?
    private(set) var method: ProviderAuthMethod?
    private(set) var prompt: LoginPrompt?
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var isFinished = false

    private let store: AccountStore
    private let openURL: (URL) -> Void
    private let login: (ProviderKind, ProviderAuthMethod, String) -> any ProviderLogin
    private var task: Task<Void, Never>?
    private var codeInput: AsyncStream<String>.Continuation?

    init(
        store: AccountStore,
        openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        login: @escaping (ProviderKind, ProviderAuthMethod, String) -> any ProviderLogin = ProviderLoginCatalog.login(for:method:organization:)
    ) {
        self.store = store
        self.openURL = openURL
        self.login = login
    }

    var canAddKey: Bool {
        !apiKey.trimmed.isEmpty && !isWorking && (method != .organizationToken || !organization.trimmed.isEmpty)
    }
    var hasPastedCode: Bool { !pastedCode.trimmed.isEmpty }
    var canSubmitCode: Bool { hasPastedCode && codeInput != nil }
    var isCodeSubmitted: Bool { isWorking && prompt != nil && codeInput == nil }

    func choose(_ kind: ProviderKind) {
        selection = kind
        provider = kind
        if kind.authMethods.count == 1 { choose(kind.authMethods[0]) }
    }

    func choose(_ method: ProviderAuthMethod) {
        self.method = method
        if method == .oauth { signIn() }
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
        method = nil
        prompt = nil
        errorMessage = nil
        isWorking = false
        apiKey = ""
        accountName = ""
        organization = ""
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
        let login = login(kind, method, organization ?? "")
        task = Task {
            do {
                let result = try await login.login(
                    prompt: { prompt in await self.show(prompt) },
                    pastedCode: input
                )
                guard !Task.isCancelled else { return }
                save(result, for: kind, organization: organization)
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

    private func save(_ result: (label: String, credential: AccountCredential), for kind: ProviderKind, organization: String?) {
        if let existing = store.account(kind: kind, organization: organization, signedInAs: result.credential) {
            return fail("This account is already added as \(existing.label).")
        }
        let name = accountName.trimmed
        let account = store.add(
            kind: kind, label: name.isEmpty ? result.label : name, organization: organization, credential: result.credential
        )
        guard store.accounts.contains(where: { $0.id == account.id }) else {
            return fail(store.lastError ?? "The account could not be saved.")
        }
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

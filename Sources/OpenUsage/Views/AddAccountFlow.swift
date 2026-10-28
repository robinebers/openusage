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
    private(set) var provider: ProviderKind?
    private(set) var prompt: LoginPrompt?
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var isFinished = false

    private let store: AccountStore
    private let openURL: (URL) -> Void
    private let login: (ProviderKind) -> any ProviderLogin
    private var task: Task<Void, Never>?
    private var codeInput: AsyncStream<String>.Continuation?

    init(
        store: AccountStore,
        openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        login: @escaping (ProviderKind) -> any ProviderLogin = ProviderLoginCatalog.login(for:)
    ) {
        self.store = store
        self.openURL = openURL
        self.login = login
    }

    var canAddKey: Bool { !apiKey.trimmed.isEmpty && !isWorking }
    var hasPastedCode: Bool { !pastedCode.trimmed.isEmpty }
    var canSubmitCode: Bool { hasPastedCode && codeInput != nil }
    var isCodeSubmitted: Bool { isWorking && prompt != nil && codeInput == nil }

    func choose(_ kind: ProviderKind) {
        selection = kind
        provider = kind
        if case .oauth = kind.authMethod { signIn() }
    }

    func signIn() {
        guard let provider else { return }
        let (input, continuation) = AsyncStream.makeStream(of: String.self)
        codeInput = continuation
        pastedCode = ""
        run(provider, input: input)
    }

    func openBrowser() {
        switch prompt {
        case .browser(let url, _): openURL(url)
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
        guard let provider, canAddKey else { return }
        let (input, continuation) = AsyncStream.makeStream(of: String.self)
        continuation.yield(apiKey)
        continuation.finish()
        run(provider, input: input)
    }

    func back() {
        cancel()
        provider = nil
        prompt = nil
        errorMessage = nil
        isWorking = false
        apiKey = ""
        accountName = ""
        pastedCode = ""
    }

    func cancel() {
        task?.cancel()
        task = nil
        codeInput?.finish()
        codeInput = nil
    }

    private func run(_ kind: ProviderKind, input: AsyncStream<String>) {
        task?.cancel()
        prompt = nil
        errorMessage = nil
        isWorking = true
        let login = login(kind)
        task = Task {
            do {
                let result = try await login.login(
                    prompt: { prompt in await self.show(prompt) },
                    pastedCode: input
                )
                guard !Task.isCancelled else { return }
                save(result, for: kind)
            } catch {
                guard !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func show(_ prompt: LoginPrompt) {
        guard !Task.isCancelled else { return }
        self.prompt = prompt
        if case .browser(let url, _) = prompt { openURL(url) }
    }

    private func save(_ result: (label: String, credential: AccountCredential), for kind: ProviderKind) {
        if let existing = store.account(kind: kind, signedInAs: result.credential) {
            return fail("This account is already added as \(existing.label).")
        }
        let name = accountName.trimmed
        let account = store.add(kind: kind, label: name.isEmpty ? result.label : name, credential: result.credential)
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

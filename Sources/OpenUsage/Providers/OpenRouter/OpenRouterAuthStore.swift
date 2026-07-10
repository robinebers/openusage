import Foundation

struct OpenRouterAuth: Hashable, Sendable {
    var apiKey: String
}

enum OpenRouterAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case credentialStoreUnreadable
    case invalidCredentialData
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .credentialStoreUnreadable: self = .credentialStoreUnreadable
        case .invalidCredentialData: self = .invalidCredentialData
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No OpenRouter API key. Set OPENROUTER_API_KEY or add it to ~/.config/openusage/openrouter.json."
        case .credentialStoreUnreadable:
            return "Couldn't read a saved OpenRouter API key. Check the config file's permissions, then try again."
        case .invalidCredentialData:
            return "A saved OpenRouter API key is invalid. Replace or remove it in the API Key editor."
        case .invalidKey:
            return "OpenRouter API key invalid. Check your key at openrouter.ai/keys."
        case .saveFailed:
            return "Couldn't save the OpenRouter API key."
        case .deleteFailed:
            return "Couldn't remove the saved OpenRouter API key."
        }
    }
}

/// Reads an OpenRouter API key the user has already placed on the machine. Unlike the CLI-backed
/// providers, OpenRouter has no companion app that stashes a credential in a known spot, so the key
/// comes from an environment variable or a small config file. A GUI app launched from Finder/Dock
/// doesn't inherit the interactive shell environment, so `ProcessEnvironmentReader` captures the
/// login shell's environment at launch (see `LoginShellEnvironment`) — meaning an env var exported in
/// a shell profile is honored even in a packaged build; the config file remains the explicit path.
struct OpenRouterAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the key.
    static let configPaths = [
        "~/.config/openusage/openrouter.json",
        "~/.config/openrouter/key.json"
    ]
    /// Environment variables checked in order. `OPENROUTER_API_KEY` is the de-facto standard.
    static let environmentNames = ["OPENROUTER_API_KEY", "OPENROUTER_KEY"]

    private let store: UserAPIKeyStore

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { OpenRouterAuthError($0) }
        )
    }

    func loadAPIKey() throws -> OpenRouterAuth? { try store.loadKey().map(OpenRouterAuth.init(apiKey:)) }
    func editorSnapshot() -> APIKeyEditorSnapshot { store.editorSnapshot() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}

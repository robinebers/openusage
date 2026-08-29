import Foundation

struct OrcaRouterAuth: Hashable, Sendable {
    var apiKey: String
}

enum OrcaRouterAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No OrcaRouter API key. Set ORCAROUTER_API_KEY or add it to ~/.config/openusage/orcarouter.json."
        case .invalidKey:
            return "OrcaRouter API key invalid. Check your key at orcarouter.ai."
        case .saveFailed:
            return "Couldn't save the OrcaRouter API key."
        case .deleteFailed:
            return "Couldn't remove the saved OrcaRouter API key."
        }
    }
}

/// Reads an OrcaRouter API key the user has already placed on the machine. Like OpenRouter, OrcaRouter
/// has no companion app that stashes a credential in a known spot, so the key comes from an environment
/// variable or a small config file. A GUI app launched from Finder/Dock doesn't inherit the interactive
/// shell environment, so `ProcessEnvironmentReader` captures the login shell's environment at launch (see
/// `LoginShellEnvironment`) — meaning an env var exported in a shell profile is honored even in a
/// packaged build; the config file remains the explicit path.
struct OrcaRouterAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the key.
    static let configPaths = [
        "~/.config/openusage/orcarouter.json",
        "~/.config/orcarouter/key.json"
    ]
    /// Environment variables checked in order. `ORCAROUTER_API_KEY` is the de-facto standard.
    static let environmentNames = ["ORCAROUTER_API_KEY", "ORCAROUTER_KEY"]

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
            makeError: { OrcaRouterAuthError($0) }
        )
    }

    func loadAPIKey() -> OrcaRouterAuth? { store.loadKey().map(OrcaRouterAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}

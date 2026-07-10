import Foundation

struct ZAIAuth: Hashable, Sendable {
    var apiKey: String
}

enum ZAIAuthError: Error, LocalizedError, Equatable {
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
            return "No Z.ai API key. Set ZAI_API_KEY or add it to ~/.config/openusage/zai.json."
        case .invalidKey:
            return "Z.ai API key invalid. Check your key at z.ai/manage-apikey/apikey-list."
        case .saveFailed:
            return "Couldn't save the Z.ai API key."
        case .deleteFailed:
            return "Couldn't remove the saved Z.ai API key."
        }
    }
}

/// Reads a [Z.ai](https://z.ai) (Zhipu AI) API key the user has already placed on the machine. Like
/// OpenRouter, Z.ai has no companion CLI/app that stashes a credential in a known spot, so the key
/// comes from an environment variable or a small config file. A GUI app launched from Finder/Dock
/// doesn't inherit the interactive shell environment, so `ProcessEnvironmentReader` captures the
/// login shell's environment at launch (see `LoginShellEnvironment`) — meaning an env var exported
/// in a shell profile is honored even in a packaged build; the config file remains the explicit path.
///
/// `ZAI_API_KEY` is the primary name; `GLM_API_KEY` is accepted as a fallback (the older Zhipu name
/// some users still export), mirroring the legacy plugin's lookup order.
struct ZAIAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the key.
    static let configPaths = [
        "~/.config/openusage/zai.json",
        "~/.config/zai/key.json"
    ]
    /// Environment variables checked in order. `ZAI_API_KEY` is current; `GLM_API_KEY` is the legacy
    /// Zhipu name some users still have exported.
    static let environmentNames = ["ZAI_API_KEY", "GLM_API_KEY"]

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
            makeError: { ZAIAuthError($0) }
        )
    }

    func loadAPIKey() -> ZAIAuth? { store.loadKey().map(ZAIAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}

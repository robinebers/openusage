import Foundation

struct DeepSeekAuth: Hashable, Sendable {
    var apiKey: String
}

enum DeepSeekAuthError: Error, LocalizedError, Equatable {
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
            return "No DeepSeek API key. Set DEEPSEEK_API_KEY or add it to ~/.config/openusage/deepseek.json."
        case .invalidKey:
            return "DeepSeek API key invalid. Check your key at platform.deepseek.com/api_keys."
        case .saveFailed:
            return "Couldn't save the DeepSeek API key."
        case .deleteFailed:
            return "Couldn't remove the saved DeepSeek API key."
        }
    }
}

struct DeepSeekAuthStore: Sendable {
    static let configPaths = [
        "~/.config/openusage/deepseek.json"
    ]
    static let environmentNames = ["DEEPSEEK_API_KEY"]

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
            makeError: { DeepSeekAuthError($0) }
        )
    }

    func loadAPIKey() -> DeepSeekAuth? { store.loadKey().map(DeepSeekAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}

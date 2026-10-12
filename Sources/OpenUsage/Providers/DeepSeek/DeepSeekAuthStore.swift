import Foundation

struct DeepSeekAuthStore: Sendable {
    static let configPaths = ["~/.config/openusage/deepseek.json"]
    static let environmentNames = ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]

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

    func loadAPIKey() -> String? { store.loadKey() }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}

enum DeepSeekAuthError: Error, LocalizedError, CategorizedError, Equatable {
    case missingKey, invalidKey, saveFailed, deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .missingKey: .notLoggedIn
        case .invalidKey: .authInvalid
        case .saveFailed, .deleteFailed: .other
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "No DeepSeek API key. Add it in Customize → DeepSeek → API Key or set DEEPSEEK_API_KEY."
        case .invalidKey:
            "DeepSeek API key invalid. Check your key at platform.deepseek.com/api_keys."
        case .saveFailed: "Couldn't save the DeepSeek API key."
        case .deleteFailed: "Couldn't remove the saved DeepSeek API key."
        }
    }
}

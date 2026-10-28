import Foundation

enum LoginPrompt: Sendable {
    case browser(URL, acceptsPastedCode: Bool)
    case deviceCode(userCode: String, verificationURL: URL)
}

protocol ProviderLogin: Sendable {
    func login(
        prompt: @Sendable (LoginPrompt) async -> Void,
        pastedCode: AsyncStream<String>
    ) async throws -> (label: String, credential: AccountCredential)
}

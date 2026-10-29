import Foundation

enum LoginPrompt: Sendable {
    case browser(URL, acceptsPastedCode: Bool)
    /// The page shows a token for the user to paste into the sheet. Nothing comes back to the app on its own.
    case browserToken(URL)
    case deviceCode(userCode: String, verificationURL: URL)
}

protocol ProviderLogin: Sendable {
    func login(
        prompt: @Sendable (LoginPrompt) async -> Void,
        pastedCode: AsyncStream<String>
    ) async throws -> (label: String, credential: AccountCredential)
}

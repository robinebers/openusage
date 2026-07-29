import Foundation

/// A `ProviderRuntime` whose credential is a captured web session rather than a static API key
/// (currently Qwen Cloud — its plan-usage API is cookies-only). The provider's Customize detail
/// renders a session card (Sign In / Sign Out) instead of the API Key editor; both paths write the
/// same config file the auth store already reads, so there is no parallel credential storage.
@MainActor
protocol SessionManaging: ProviderRuntime {
    /// Whether a captured session currently exists locally — a file probe, never the network.
    var hasSession: Bool { get }
    /// Open the interactive sign-in. The completion runs exactly once on the main actor:
    /// `.success` when a fresh session was captured and persisted, `.failure` otherwise
    /// (including `QwenAuthError.signInCancelled` when the window closed early).
    func beginSignIn(completion: @escaping @MainActor (Result<Void, Error>) -> Void)
    /// Remove the saved session. The browser-side cookies are kept so the next sign-in can
    /// recapture a still-live session silently.
    func signOut() throws
}

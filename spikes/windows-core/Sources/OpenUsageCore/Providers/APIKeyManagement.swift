import Foundation

/// The live status of a provider's user-supplied API key, shown in Settings ▸ API Keys. Maps to the
/// four states the OpenRouter API-key UX canvas renders:
///
/// - `notSet`: no key in the environment or the saved file — the card offers an Add field.
/// - `fromEnvironment`: a key is present in the environment only — shown read-only, with an
///   override checkbox.
/// - `saved`: a key was saved via the app (written to the config file) and no env key is present —
///   "Connected", with Replace / Remove.
/// - `overrideActive`: a saved key is overriding a key also present in the environment — "Custom
///   key", with Edit / Clear override (clearing falls back to the env key).
///
/// The auth store's existing precedence (config file > env) is what makes a saved key an override
/// for free; this type just reports which combination is present.
enum APIKeyStatus: Sendable, Equatable {
    case notSet
    case fromEnvironment
    case saved
    case overrideActive
}

/// A `ProviderRuntime` that needs a user-supplied API key (OpenRouter today; future user-key
/// providers conform later). Settings ▸ API Keys lists conformers, renders each one's
/// `apiKeyStatus`, and writes changes through `saveAPIKey` / `deleteAPIKey`. The provider delegates
/// to its auth store, so the UI stays provider-agnostic and the storage path each provider already
/// reads is the one the UI writes — no new storage infra.
@MainActor
protocol APIKeyManaging: ProviderRuntime {
    /// The live key status, computed from the environment + the saved config file.
    var apiKeyStatus: APIKeyStatus { get }
    /// The effective key currently in use (config > env), surfaced only when the user clicks the
    /// reveal toggle. `nil` when no key is present.
    func currentAPIKey() -> String?
    /// Persist `key` to the storage the auth store already reads (the config file). A saved key
    /// automatically takes precedence over an env var.
    func saveAPIKey(_ key: String) throws
    /// Remove the saved key. If an env key is present the status falls back to `fromEnvironment`;
    /// otherwise `notSet`.
    func deleteAPIKey() throws
    /// User-facing description of where the key is stored, shown under the input ("Stored in …").
    var apiKeyStorageDescription: String { get }
    /// The env-var name checked, shown in the "Using OPENROUTER_API_KEY from your environment" line.
    var apiKeyEnvironmentName: String { get }
}

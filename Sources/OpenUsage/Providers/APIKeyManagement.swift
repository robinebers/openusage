import Foundation

/// The live status of a provider's user-supplied API key, shown in that provider's Customize detail.
/// Maps to the five states the API-key editor renders:
///
/// - `notSet`: no key in the environment or the saved file — the card offers an Add field.
/// - `fromEnvironment`: a key is present in the environment only — shown read-only, with an
///   override checkbox.
/// - `saved`: a key was saved via the app (written to the config file) and no environment key is
///   present — shown read-only, with reveal and Clear actions.
/// - `overrideActive`: a saved key is overriding an environment key — shown read-only, with reveal
///   and Clear actions (clearing falls back to the environment).
/// - `savedKeyError`: a saved config file exists but cannot be read or parsed — shown as needing
///   attention, with Replace and Clear actions; reveal stays disabled so a fallback is not mislabeled.
///
/// The auth store's existing precedence (config file > env) is what makes a saved key an override
/// for free; this type just reports which combination is present.
enum APIKeyStatus: Sendable, Equatable {
    case notSet
    case fromEnvironment
    case saved
    case overrideActive
    case savedKeyError
}

/// One filesystem-resolution snapshot for the editor. Status and the revealable value must travel
/// together so a hand-edited config cannot change sources between two reads and make the UI label an
/// environment fallback as a saved override (or vice versa).
struct APIKeyEditorSnapshot: Sendable, Equatable {
    let status: APIKeyStatus
    let revealableKey: String?
}

/// A `ProviderRuntime` that needs a user-supplied API key (currently OpenRouter and Z.ai). The
/// provider's Customize detail renders this shared editor and writes changes through the same storage
/// layer authentication already reads — no parallel key store.
@MainActor
protocol APIKeyManaging: ProviderRuntime {
    /// The live source status and the key that may be revealed, resolved atomically.
    var apiKeyEditorSnapshot: APIKeyEditorSnapshot { get }
    /// Persist `key` to the storage the auth store already reads (the config file). A saved key
    /// automatically takes precedence over an env var.
    func saveAPIKey(_ key: String) throws
    /// Remove the saved key. If an env key is present the status falls back to `fromEnvironment`;
    /// otherwise `notSet`.
    func deleteAPIKey() throws
}

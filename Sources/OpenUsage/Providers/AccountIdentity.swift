import Foundation

/// Resolves an account's signed-in email, dispatching to each provider's identity source (Claude's
/// `/api/oauth/profile`, Codex's `id_token`). Pass the account's config dir, or nil for the default
/// login. Returns nil for providers without an identity source or when the account isn't logged in.
/// One seam so the Accounts UI and duplicate-rejection treat every multi-account provider alike.
enum AccountIdentity {
    @MainActor
    static func email(provider: String, configDir: String?) async -> String? {
        switch provider {
        case "claude": return await ClaudeAccountIdentity.email(configDir: configDir)
        case "codex": return CodexAccountIdentity.email(configHome: configDir)
        default: return nil
        }
    }
}

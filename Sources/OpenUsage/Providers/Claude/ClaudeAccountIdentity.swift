import Foundation

/// Resolves a Claude account's email from the reliable `/api/oauth/profile` endpoint (token-derived,
/// not the flip-flopping `.claude.json`). Pass the account's config dir, or nil for the default login.
/// Used to label accounts in the Accounts settings and to reject adding a duplicate account.
enum ClaudeAccountIdentity {
    @MainActor
    static func email(configDir: String?, usageClient: ClaudeUsageClient = ClaudeUsageClient()) async -> String? {
        let environment: EnvironmentReading = configDir.map { OverrideEnvironment(["CLAUDE_CONFIG_DIR": $0]) }
            ?? ProcessEnvironmentReader()
        let authStore = ClaudeAuthStore(environment: environment)
        guard let state = authStore.loadCredentials(),
              let token = state.oauth.accessToken,
              !token.isEmpty,
              let config = try? authStore.oauthConfig()
        else { return nil }
        return await email(accessToken: token, usageClient: usageClient, config: config)
    }

    /// Shared profile lookup for an already-resolved access token (also used by `ClaudeProvider`, which
    /// holds a live token, so the request/parse/status logic lives in one place). Best-effort: returns
    /// nil on any failure — logged at debug, since identity is a labelling aid, not a gate.
    @MainActor
    static func email(accessToken: String, usageClient: ClaudeUsageClient, config: ClaudeOAuthConfig) async -> String? {
        do {
            let response = try await usageClient.fetchProfile(accessToken: accessToken, config: config)
            guard (200..<300).contains(response.statusCode) else {
                AppLog.debug(LogTag.auth("claude"), "profile lookup returned HTTP \(response.statusCode)")
                return nil
            }
            return ClaudeProfile.email(fromProfileResponse: response.body)
        } catch {
            AppLog.debug(LogTag.auth("claude"), "profile lookup failed: \(error.localizedDescription)")
            return nil
        }
    }
}

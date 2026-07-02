import Foundation

/// Resolves a Codex account's email from its `id_token` — the OpenAI OIDC token stored in `auth.json`,
/// whose payload carries a top-level `email` claim, so no network call is needed. Pass the account's
/// `CODEX_HOME`, or nil for the default login. Used to label accounts in the Accounts settings and to
/// reject adding a duplicate account.
enum CodexAccountIdentity {
    @MainActor
    static func email(configHome: String?) -> String? {
        let environment: EnvironmentReading = configHome.map { OverrideEnvironment(["CODEX_HOME": $0]) }
            ?? ProcessEnvironmentReader()
        let authStore = CodexAuthStore(environment: environment)
        let (fileCandidates, _) = authStore.loadAuthCandidates()
        let idToken = fileCandidates.lazy.compactMap { $0.auth.tokens?.idToken }.first
            ?? authStore.loadKeychainAuth()?.auth.tokens?.idToken
        return email(fromIDToken: idToken)
    }

    /// Decodes the `email` claim from an OIDC `id_token` JWT payload. Best-effort: returns nil if the
    /// token is absent, malformed, or carries no email — identity is a labelling aid, not a gate.
    static func email(fromIDToken idToken: String?) -> String? {
        guard let idToken else { return nil }
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        // JWT segments are base64url with stripped padding; restore both before decoding.
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = claims["email"] as? String,
              !email.isEmpty
        else { return nil }
        return email
    }
}

import Foundation

struct ClaudeOAuth: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?
    var rateLimitTier: String?
    var scopes: [String]?
}

/// Claude Code owns this document, including MCP logins and fields OpenUsage does not know about.
/// Keep its original JSON alongside the typed view rather than re-encoding that partial model.
struct ClaudeCredentialsFile: Hashable, Sendable {
    let claudeAiOauth: ClaudeOAuth?
    private let document: Data

    init?(data: Data) {
        struct OAuthFields: Decodable {
            var claudeAiOauth: ClaudeOAuth?
        }
        guard let fields = try? JSONDecoder().decode(OAuthFields.self, from: data) else { return nil }
        claudeAiOauth = fields.claudeAiOauth
        document = data
    }

    func mergingRotatedOAuth(_ oauth: ClaudeOAuth) throws -> String {
        guard var object = try JSONSerialization.jsonObject(with: document) as? [String: Any],
              var storedOAuth = object["claudeAiOauth"] as? [String: Any]
        else { throw ClaudeAuthError.credentialsChanged }
        // These are the only fields returned by the refresh endpoint. Leave metadata, unknown
        // nested fields, and every other credential in the document untouched.
        if let accessToken = oauth.accessToken { storedOAuth["accessToken"] = accessToken }
        if let refreshToken = oauth.refreshToken { storedOAuth["refreshToken"] = refreshToken }
        if let expiresAt = oauth.expiresAt { storedOAuth["expiresAt"] = expiresAt }
        object["claudeAiOauth"] = storedOAuth
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

struct ClaudeCredentialState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file
        case accountFile(path: String)
        case keychainCurrentUser(service: String)
        case keychainLegacy(service: String)
        case desktop
        case swapVault
        case environment

        /// Log-safe source kind , NEVER the keychain service name or any token.
        var label: String {
            switch self {
            case .file, .accountFile: "file"
            case .keychainCurrentUser: "keychainCurrentUser"
            case .keychainLegacy: "keychainLegacy"
            case .desktop: "desktop"
            case .swapVault: "swapVault"
            case .environment: "environment"
            }
        }
    }

    var oauth: ClaudeOAuth
    var source: Source
    var fullData: ClaudeCredentialsFile?
    var inferenceOnly: Bool

    /// Whether this candidate carries a non-blank access token , the single definition of "usable"
    /// shared by `refresh()`'s candidate filter and `hasLocalCredentials()`'s first-run detection, so
    /// the two can never drift.
    var hasUsableAccessToken: Bool {
        oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// A token-free, log-safe one-line descriptor for diagnosing auth failures from a default-level
    /// (info) log: the source kind plus booleans for whether this candidate carries a refresh token and
    /// whether its access token is already expired (`expiresAt`, epoch ms, vs `now`). NEVER includes any
    /// token value or the credential blob , only the source kind and the two booleans. Why these two
    /// booleans: a candidate with `refresh=no` can never self-heal an expiry (the #738 root cause), and
    /// `expired=yes` explains why a refresh was needed at all.
    func diagnosticsLabel(now: Date) -> String {
        let refresh = (oauth.refreshToken?.isEmpty == false) ? "yes" : "no"
        let expired: String
        if let expiresAt = oauth.expiresAt {
            expired = expiresAt <= now.timeIntervalSince1970 * 1000 ? "yes" : "no"
        } else {
            expired = "unknown"
        }
        return "\(source.label) refresh=\(refresh) expired=\(expired)"
    }
}

/// Token-bearing credential candidates in their effective probe order. Environment-only inference
/// tokens are excluded because they never fetch live usage; every stored candidate that can affect
/// selection remains, including an earlier source that the current refresh already tried and rejected.
struct ClaudeCredentialGeneration: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let oauth: ClaudeOAuth
        let source: ClaudeCredentialState.Source

        init(_ state: ClaudeCredentialState) {
            oauth = state.oauth
            source = state.source
        }
    }

    var candidates: [Candidate]

    init(_ states: [ClaudeCredentialState]) {
        candidates = states
            .filter { $0.hasUsableAccessToken && !$0.inferenceOnly }
            .map(Candidate.init)
    }

    func replacing(_ state: ClaudeCredentialState) -> Self {
        var updated = self
        guard let index = updated.candidates.firstIndex(where: { $0.source == state.source }) else {
            fatalError("live usage source missing from Claude credential generation")
        }
        updated.candidates[index] = Candidate(state)
        return updated
    }
}

struct ClaudeCredentialLoad: Sendable {
    var candidates: [ClaudeCredentialState]
    var desktopStatus: ClaudeDesktopCredentialStatus
}

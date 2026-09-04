import Foundation

// The Desktop cache is external input. Resolve account-scoped keys before ranking usage tokens.
extension ClaudeDesktopAuthStore {
    private static let apiHost = "https://api.anthropic.com"
    private static let usageScope = "user:profile"
    private static let expirySafetyMarginMs = 2 * 60 * 1000.0

    enum Selection: Sendable {
        case available(ClaudeOAuth)
        case stale
        case notFound
        case invalid
    }

    static func selectCredential(
        activeOrganization: String,
        activeAccountUUID: String? = nil,
        v2: [String: Any]?,
        v1: [String: Any]?,
        now: Date
    ) -> Selection {
        let normalizedOrg = activeOrganization.lowercased()
        let v2Entries = normalizedCache(v2, activeAccountUUID: activeAccountUUID)
        let v1Entries = normalizedCache(v1, activeAccountUUID: activeAccountUUID)
        let v2Candidates = candidates(in: v2Entries, organization: normalizedOrg, now: now)
        if let best = v2Candidates.available.max(by: { $0.rank < $1.rank }) {
            return .available(best.oauth)
        }

        let v1Candidates = candidates(
            in: v1Entries.filter { v2Entries[$0.key] == nil },
            organization: normalizedOrg,
            now: now
        )
        if let best = v1Candidates.available.max(by: { $0.rank < $1.rank }) {
            return .available(best.oauth)
        }
        if v2Candidates.sawStale || v1Candidates.sawStale { return .stale }
        if v2Candidates.sawInvalid || v1Candidates.sawInvalid { return .invalid }
        return .notFound
    }

    /// The OAuth client ID Claude's production login (Claude Code / Desktop) mints full-scope tokens
    /// under. Desktop's cache can hold several entries for one org — partial-scope leftovers from older
    /// logins included — and this client is how Desktop itself resolves the active login.
    private static let productionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let inferenceScope = "user:inference"

    private struct Candidate {
        var oauth: ClaudeOAuth
        var clientID: String
        var scopes: [String]
        var expiresAt: Double

        /// Selection order mirrors Desktop's own resolution instead of raw expiry: production client
        /// with full scopes first, then any full-scope entry over bare `user:profile` leftovers, then
        /// scope richness, with expiry only as the final tiebreak. A stale wrong-tier token with a
        /// longer TTL must not outrank the current login.
        var rank: (Int, Int, Int, Double) {
            let hasFullScope = scopes.contains(ClaudeDesktopAuthStore.usageScope)
                && scopes.contains(ClaudeDesktopAuthStore.inferenceScope)
            let isProductionClient = clientID == ClaudeDesktopAuthStore.productionClientID
            return (
                isProductionClient && hasFullScope ? 1 : 0,
                hasFullScope ? 1 : 0,
                scopes.count,
                expiresAt
            )
        }
    }

    private static func candidates(
        in cache: [CacheKey: Any],
        organization: String,
        now: Date
    ) -> (available: [Candidate], sawStale: Bool, sawInvalid: Bool) {
        var available: [Candidate] = []
        var sawStale = false
        var sawInvalid = false
        for (parsedKey, rawEntry) in cache {
            guard parsedKey.organization == organization,
                  parsedKey.apiHost == apiHost,
                  parsedKey.scopes.contains(usageScope)
            else {
                continue
            }
            guard !(rawEntry is NSNull) else { continue }
            guard let entry = rawEntry as? [String: Any],
                  let token = entry["token"] as? String,
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let expiresAt = number(entry["expiresAt"]),
                  expiresAt.isFinite
            else {
                sawInvalid = true
                continue
            }
            guard expiresAt > now.timeIntervalSince1970 * 1000 + expirySafetyMarginMs else {
                sawStale = true
                continue
            }
            let oauth = ClaudeOAuth(
                accessToken: token,
                refreshToken: nil,
                expiresAt: expiresAt,
                subscriptionType: entry["subscriptionType"] as? String,
                rateLimitTier: entry["rateLimitTier"] as? String,
                scopes: parsedKey.scopes
            )
            available.append(Candidate(
                oauth: oauth,
                clientID: parsedKey.clientID,
                scopes: parsedKey.scopes,
                expiresAt: expiresAt
            ))
        }
        return (available, sawStale, sawInvalid)
    }

    private struct CacheKey: Hashable {
        var clientID: String
        var organization: String
        var apiHost: String
        var scopes: [String]
    }

    /// Desktop migrates legacy keys to `acct:<user>|<legacy key>` on use. A scoped entry,
    /// including a deletion marker, supersedes its legacy alias. Foreign accounts never
    /// participate in selection or suppress the current account's V1 fallback.
    private static func normalizedCache(
        _ cache: [String: Any]?, activeAccountUUID: String?
    ) -> [CacheKey: Any] {
        guard let cache else { return [:] }
        var legacy: [CacheKey: Any] = [:]
        var scoped: [CacheKey: Any] = [:]
        for (rawKey, entry) in cache.sorted(by: { $0.key < $1.key }) {
            let isScoped = rawKey.hasPrefix("acct:")
            var key = rawKey
            if isScoped {
                guard let separator = rawKey.firstIndex(of: "|"),
                      let owner = UUID(uuidString: String(rawKey.dropFirst(5).prefix(upTo: separator))),
                      let activeAccountUUID, let active = UUID(uuidString: activeAccountUUID),
                      owner == active
                else { continue }
                key = String(rawKey[rawKey.index(after: separator)...])
            }
            guard let parsed = parseCacheKey(key) else { continue }
            if isScoped { scoped[parsed] = entry } else { legacy[parsed] = entry }
        }
        return legacy.merging(scoped) { _, scopedEntry in scopedEntry }
    }

    private static func parseCacheKey(_ value: String) -> CacheKey? {
        let marker = ":\(apiHost):"
        guard let markerRange = value.range(of: marker) else { return nil }
        let prefix = value[..<markerRange.lowerBound]
        guard let firstColon = prefix.firstIndex(of: ":") else { return nil }
        let clientID = String(prefix[..<firstColon]).lowercased()
        let organization = String(prefix[prefix.index(after: firstColon)...]).lowercased()
        guard UUID(uuidString: clientID) != nil, UUID(uuidString: organization) != nil else {
            return nil
        }
        let scopes = value[markerRange.upperBound...]
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return CacheKey(clientID: clientID, organization: organization, apiHost: apiHost, scopes: scopes)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

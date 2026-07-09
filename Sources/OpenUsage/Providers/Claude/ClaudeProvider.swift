import CryptoKit
import Foundation

@MainActor
final class ClaudeProvider: ProviderRuntime {
    let provider = Provider(
        id: "claude",
        displayName: "Claude",
        icon: .providerMark("claude"),
        links: [
            .init(label: "Status", url: "https://status.anthropic.com/"),
            .init(label: "Dashboard", url: "https://claude.ai/settings/usage")
        ]
    )

    let authStore: ClaudeAuthStore
    let usageClient: ClaudeUsageClient
    let logUsageScanner: ClaudeLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    /// Last successful live usage and its rate-limit cooldown, scoped to a one-way fingerprint of the
    /// access + refresh credential pair that produced them. The provider is long-lived while users can
    /// re-login or switch sources underneath it; access-token-only identity is insufficient because an
    /// external edit can replace the refresh token before OpenUsage observes the next rotation.
    /// A successful OAuth refresh migrates state only when the complete pre-refresh identity still
    /// matches the cache. Unobserved credential-file changes deliberately do not.
    private struct LiveUsageCache {
        let credentialFingerprint: Data
        var lastGoodUsage: ClaudeMappedUsage?
        var rateLimitedUntil: Date?
    }

    private var liveUsageCache: LiveUsageCache?
    private static let rateLimitCooldown: TimeInterval = 5 * 60

    init(
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        usageClient: ClaudeUsageClient = ClaudeUsageClient(),
        logUsageScanner: ClaudeLogUsageScanner = ClaudeLogUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "claude.session", provider: provider, title: "Session", isSessionWindow: true),
            .percent(id: "claude.weekly", provider: provider, title: "Weekly"),
            .percent(id: "claude.sonnet", provider: provider, title: "Sonnet"),
            .percent(id: "claude.fable", provider: provider, title: "Fable"),
            .boundedDollars(id: "claude.extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage spent", limit: 100, valueWord: "spent"),
            .usageTrend(provider: provider)
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources and same usability filter as `refresh()` (see `hasUsableAccessToken`).
        await loadOffMainActor { [authStore] in authStore.loadCredentialCandidates() }
            .contains(where: \.hasUsableAccessToken)
    }

    func refresh() async -> ProviderSnapshot {
        await refresh(credentialReloadsRemaining: 1)
    }

    /// A Claude Code login can replace credentials while an OAuth refresh is suspended. Reload the
    /// candidate set once when that happens so the stale account cannot reach the UI or live-usage
    /// cache. Bound the retry so a source that changes continuously cannot trap the refresh loop.
    private func refresh(credentialReloadsRemaining: Int) async -> ProviderSnapshot {
        let storedCandidates = await loadOffMainActor { [authStore] in authStore.loadCredentialCandidates() }
        let candidates = storedCandidates.filter(\.hasUsableAccessToken)
        guard !candidates.isEmpty else {
            // No CLI credentials anywhere. A login done only in the Claude desktop app is stored in an
            // Electron-encrypted blob OpenUsage can't read, so a bare "Not logged in" reads as wrong to
            // a user who is clearly signed in (#825) — point them at the one-time CLI login instead.
            // Gated on the store finding nothing at all: a stored-but-blank token means the CLI *did*
            // write credentials, so the plain "Not logged in" is the right guidance there.
            if storedCandidates.isEmpty, await loadOffMainActor({ [authStore] in authStore.hasDesktopAppData() }) {
                AppLog.info(LogTag.auth("claude"), "no CLI credentials, but desktop app data found — CLI login needed")
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopAppOnly)
            }
            AppLog.info(LogTag.auth("claude"), "no access token, not logged in")
            return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.notLoggedIn)
        }

        // Per-source diagnostics at info level (token-free: source kind + refresh-token-present + expired
        // booleans) so a "token expired" report is diagnosable from a default log without a debug build —
        // e.g. all sources showing `refresh=no` explains why an expiry can never self-heal (issue #738).
        let sources = candidates.map { $0.diagnosticsLabel(now: now()) }.joined(separator: ", ")
        AppLog.info(LogTag.plugin("claude"), "refresh start (\(candidates.count) source\(candidates.count == 1 ? "" : "s"): \(sources))")
        let start = Date()
        // Probe each credential source in keychain-before-file order. An auth-expiry failure on one source (a
        // stale/locked-out token that an external `claude` re-login replaced in another source) falls
        // through to the next rather than failing the whole refresh; any non-auth error (rate limit,
        // request/transport failure) surfaces immediately so a real outage is never masked as a retry.
        var lastFallbackError: Error?
        for state in candidates {
            do {
                let snapshot = try await probe(state: state)
                AppLog.info(LogTag.plugin("claude"), "refresh end (\(Int(Date().timeIntervalSince(start) * 1000))ms)")
                return snapshot
            } catch ClaudeAuthError.credentialsChanged where credentialReloadsRemaining > 0 {
                AppLog.info(LogTag.auth("claude"), "credential source changed during token refresh; reloading current login")
                return await refresh(credentialReloadsRemaining: credentialReloadsRemaining - 1)
            } catch let error as ClaudeAuthError where error.allowsAuthFallback {
                AppLog.warn(LogTag.auth("claude"), "\(state.source.label) failed (\(error)); falling back to next source if any")
                lastFallbackError = error
                continue
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }
        return ProviderSnapshot.error(
            provider: provider,
            error: lastFallbackError ?? ClaudeAuthError.notLoggedIn
        )
    }

    private func probe(state initialState: ClaudeCredentialState) async throws -> ProviderSnapshot {
        var state = initialState
        var mapped = ClaudeMappedUsage(
            plan: ClaudeUsageMapper.formatPlan(
                subscriptionType: state.oauth.subscriptionType,
                rateLimitTier: state.oauth.rateLimitTier
            ),
            lines: []
        )

        var warning: String?
        switch authStore.liveUsageAvailability(state) {
        case .available:
            mapped = try await fetchLiveUsage(state: &state)
            // A rate-limited fetch rides its "Updates blocked by Anthropic" notice on the mapped usage so
            // it reaches the header triangle even when the badge/note lines aren't in the user's layout.
            warning = mapped.warning
        case .missingProfileScope:
            // The login authenticates for inference but lacks the `user:profile` scope the usage endpoint
            // needs (typically a `claude setup-token` token). Don't leave the session/weekly bars silently
            // blank — log it for diagnosis and surface a provider header warning (the amber triangle, like
            // Z.ai's "no coding plan" notice) telling the user a re-login restores them. The local-log
            // spend tiles below are unaffected and still load.
            AppLog.warn(LogTag.plugin("claude"), "live usage unavailable: credential lacks the user:profile scope (inference-only token); re-login with `claude` to restore session/weekly limits")
            warning = ClaudeUsageMapper.missingProfileScopeWarning
        case .inferenceOnlyToken:
            // An explicit CLAUDE_CODE_OAUTH_TOKEN is inference-only by design; nothing to fetch and nothing
            // to nag about — the spend tiles still load below.
            break
        }

        // Local spend tiles, scanned natively from Claude Code's session logs and priced through the
        // shared pricing store. `scan` runs on the scanner actor, off the main actor.
        if let scan = await logUsageScanner.scan(now: now(), pricing: pricing()) {
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &mapped.lines, now: now(),
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: "From your Claude usage history (estimated)"
            )
            SpendTileMapper.appendUsageTrend(
                scan.series, to: &mapped.lines, now: now(),
                note: "From your Claude usage history (estimated)"
            )
        }

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now(), warning: warning)
    }

    private func fetchLiveUsage(state: inout ClaudeCredentialState) async throws -> ClaudeMappedUsage {
        // Resolve caller-controlled endpoint configuration once, before the authenticated retry helper.
        // A malformed custom URL is an auth/config error, not a transport failure from the HTTP attempt.
        let oauthConfig = try authStore.oauthConfig()

        // Inside an active rate-limit cooldown, skip the live call and serve the last-good usage so a
        // constantly-limited endpoint doesn't blank the dashboard (and we don't pile on more 429s).
        let initialFingerprint = Self.credentialFingerprint(state.oauth)
        if let cache = liveUsageCache,
           cache.credentialFingerprint == initialFingerprint,
           let until = cache.rateLimitedUntil,
           now() < until {
            AppLog.info(LogTag.plugin("claude"), "rate-limited (cooldown active, serving \(cache.lastGoodUsage == nil ? "badge" : "last-good usage"))")
            return rateLimitedSnapshot(
                credentials: state.oauth,
                credentialFingerprint: initialFingerprint,
                retryAfterSeconds: Int(until.timeIntervalSince(now()).rounded(.up))
            )
        }

        if authStore.needsRefresh(state.oauth), let refreshToken = state.usableRefreshToken {
            state.oauth.accessToken = try await refreshAccessToken(
                state: &state,
                refreshToken: refreshToken,
                config: oauthConfig
            )
        }

        var working = state
        defer { state = working }
        let response = try await ProviderAuthRetry.fetch(
            token: working.oauth.accessToken ?? "",
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0, config: oauthConfig) },
            refreshAccessToken: {
                guard let refreshToken = working.usableRefreshToken else {
                    throw ClaudeAuthError.tokenExpired
                }
                return try await self.refreshAccessToken(
                    state: &working,
                    refreshToken: refreshToken,
                    config: oauthConfig
                )
            },
            connectionFailed: ClaudeUsageError.connectionFailed,
            authExpired: ClaudeAuthError.tokenExpired
        )

        // 429 can come back from either attempt; the helper hands both through unchanged. Start a cooldown
        // (respecting Retry-After) and serve the last-good usage rather than a bare badge.
        if response.statusCode == 429 {
            let retryAfterSeconds = ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now())
            let fingerprint = Self.credentialFingerprint(working.oauth)
            let matchingLastGood = liveUsageCache?.credentialFingerprint == fingerprint
                ? liveUsageCache?.lastGoodUsage
                : nil
            liveUsageCache = LiveUsageCache(
                credentialFingerprint: fingerprint,
                lastGoodUsage: matchingLastGood,
                rateLimitedUntil: now().addingTimeInterval(
                    TimeInterval(retryAfterSeconds ?? Int(Self.rateLimitCooldown))
                )
            )
            AppLog.info(LogTag.plugin("claude"), "rate-limited (serving \(matchingLastGood == nil ? "badge" : "last-good usage"))")
            return rateLimitedSnapshot(
                credentials: working.oauth,
                credentialFingerprint: fingerprint,
                retryAfterSeconds: retryAfterSeconds
            )
        }

        let mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: working.oauth, now: now())
        liveUsageCache = LiveUsageCache(
            credentialFingerprint: Self.credentialFingerprint(working.oauth),
            lastGoodUsage: mapped,
            rateLimitedUntil: nil
        )
        return mapped
    }

    /// Last-good usage with an appended staleness note when we have it; otherwise the plain rate-limited
    /// badge. The fingerprint match is mandatory: changing login or credential source must never expose
    /// the previous token's quota. Cached usage only ever holds a clean `mapUsageResponse` result, so the
    /// note is never duplicated and no stale spend tiles ride along—`probe` appends those fresh afterward.
    private func rateLimitedSnapshot(
        credentials: ClaudeOAuth,
        credentialFingerprint: Data,
        retryAfterSeconds: Int?
    ) -> ClaudeMappedUsage {
        guard let cache = liveUsageCache,
              cache.credentialFingerprint == credentialFingerprint,
              var mapped = cache.lastGoodUsage else {
            return ClaudeUsageMapper.rateLimitedUsage(credentials: credentials, retryAfterSeconds: retryAfterSeconds)
        }
        mapped.lines.append(ClaudeUsageMapper.rateLimitedNote(retryAfterSeconds: retryAfterSeconds))
        mapped.warning = ClaudeUsageMapper.rateLimitedWarning(retryAfterSeconds: retryAfterSeconds)
        return mapped
    }

    /// A non-reversible in-memory identity for cache partitioning. Hash the access and refresh token
    /// separately before combining their fixed-width digests, so no delimiter ambiguity is possible.
    /// Never logged or persisted.
    private static func credentialFingerprint(_ credentials: ClaudeOAuth) -> Data {
        guard let accessToken = credentials.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            preconditionFailure("live usage requires a validated access token")
        }
        let refreshToken = credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var identity = Data(SHA256.hash(data: Data(accessToken.utf8)))
        identity.append(contentsOf: SHA256.hash(data: Data(refreshToken.utf8)))
        return Data(SHA256.hash(data: identity))
    }

    /// Carry last-good usage and cooldown state across a rotation OpenUsage performed itself, but only
    /// when the cache matches the complete pre-refresh access + refresh identity. A refresh response
    /// authenticates the refresh token, not the access token; requiring both prevents an externally
    /// swapped refresh token from relabeling another account's cached quota.
    private func migrateLiveUsageCache(from previousCredentials: ClaudeOAuth, to refreshedCredentials: ClaudeOAuth) {
        let previousFingerprint = Self.credentialFingerprint(previousCredentials)
        let refreshedFingerprint = Self.credentialFingerprint(refreshedCredentials)
        guard previousFingerprint != refreshedFingerprint,
              let cache = liveUsageCache,
              cache.credentialFingerprint == previousFingerprint else {
            return
        }
        liveUsageCache = LiveUsageCache(
            credentialFingerprint: refreshedFingerprint,
            lastGoodUsage: cache.lastGoodUsage,
            rateLimitedUntil: cache.rateLimitedUntil
        )
    }

    private func refreshAccessToken(
        state: inout ClaudeCredentialState,
        refreshToken: String,
        config: ClaudeOAuthConfig
    ) async throws -> String {
        AppLog.info(LogTag.auth("claude"), "token refresh attempt")
        let response: HTTPResponse
        do {
            response = try await usageClient.refreshToken(refreshToken, config: config)
        } catch is HTTPClientError {
            AppLog.warn(LogTag.auth("claude"), "token refresh returned an invalid HTTP response")
            throw ClaudeUsageError.invalidResponse
        } catch is URLError {
            AppLog.warn(LogTag.auth("claude"), "token refresh request failed")
            throw ClaudeUsageError.connectionFailed
        } catch {
            AppLog.warn(LogTag.auth("claude"), "token refresh failed before receiving a response")
            throw error
        }
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            let errorCode = body?["error"] as? String ?? body?["error_description"] as? String
            if errorCode == "invalid_grant" {
                AppLog.warn(LogTag.auth("claude"), "session expired (invalid_grant)")
                throw ClaudeAuthError.sessionExpired
            }
            // A 400/401 without a recognized OAuth error code isn't necessarily an expired token — it
            // can be an HTML proxy/WAF page or a gateway error. Surface the HTTP status rather than
            // telling the user to re-login (which can't fix a transport/infra failure).
            AppLog.warn(LogTag.auth("claude"), "token refresh failed (HTTP \(response.statusCode))")
            throw ClaudeUsageError.requestFailed(response.statusCode)
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(LogTag.auth("claude"), "token refresh failed (HTTP \(response.statusCode))")
            throw ClaudeUsageError.requestFailed(response.statusCode)
        }

        let decoded: ClaudeRefreshResponse
        do {
            decoded = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: response.body)
        } catch {
            AppLog.warn(LogTag.auth("claude"), "token refresh response was invalid")
            throw ClaudeUsageError.invalidResponse
        }
        let accessToken = decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            AppLog.warn(LogTag.auth("claude"), "token refresh response contained an empty access token")
            throw ClaudeUsageError.invalidResponse
        }
        let expiresAt: Double?
        if let expiresIn = decoded.expiresIn {
            let candidate = now().timeIntervalSince1970 * 1000 + expiresIn * 1000
            guard expiresIn.isFinite, expiresIn > 0, candidate.isFinite else {
                AppLog.warn(LogTag.auth("claude"), "token refresh response contained invalid expiry metadata")
                throw ClaudeUsageError.invalidResponse
            }
            expiresAt = candidate
        } else {
            expiresAt = nil
        }

        // Validate the complete response before changing either in-memory state or persisted credentials.
        // NEVER log access or refresh tokens — only the fact that a validated rotation happened.
        let previousCredentials = state.oauth
        var refreshedState = state
        refreshedState.oauth.accessToken = accessToken
        if let refreshToken = decoded.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refreshToken.isEmpty {
            refreshedState.oauth.refreshToken = refreshToken
        }
        // A missing expiry means unknown, not "reuse the old token's already-expired deadline".
        refreshedState.oauth.expiresAt = expiresAt
        // Fail loudly: a swallowed save leaves the OLD refresh token on disk after a rotation, so the
        // next launch refreshes with a server-invalidated token and the user sees a misleading
        // "session expired". The refreshed token still works for this session, so we log and continue
        // rather than fail the live fetch.
        let persisted: Bool?
        do {
            persisted = try await Task.detached(priority: .utility) { [authStore] in
                try authStore.save(refreshedState, replacing: previousCredentials)
            }.value
        } catch {
            AppLog.error(LogTag.auth("claude"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
            persisted = nil
        }
        // A false result means Claude Code replaced this source while the token request was in flight.
        // Do not install, query with, or cache the stale account's rotation; the outer refresh reloads
        // the current source once and starts over with the newly active login.
        guard persisted != false else {
            throw ClaudeAuthError.credentialsChanged
        }
        state = refreshedState
        migrateLiveUsageCache(from: previousCredentials, to: refreshedState.oauth)
        AppLog.info(LogTag.auth("claude"), "token refresh ok (rotated)")
        return accessToken
    }

}

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
    let ccusageRunner: CcusageRunner
    let now: @Sendable () -> Date

    /// Last successful live-usage result and a rate-limit cooldown, carried across refreshes (the provider
    /// is a long-lived singleton). `/api/oauth/usage` rate-limits aggressively, so on a 429 we serve the
    /// last-good bars with a staleness note instead of blanking the dashboard, and skip the live call
    /// entirely until the cooldown expires so we don't keep hammering an endpoint that's already limiting
    /// us. Mirrors the legacy plugin's `cachedUsageData` + `rateLimitedUntilMs`.
    private var lastGoodUsage: ClaudeMappedUsage?
    private var rateLimitedUntil: Date?
    private static let rateLimitCooldown: TimeInterval = 5 * 60

    init(
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        usageClient: ClaudeUsageClient = ClaudeUsageClient(),
        ccusageRunner: CcusageRunner = CcusageRunner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.ccusageRunner = ccusageRunner
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "claude.session", provider: provider, title: "Session"),
            .percent(id: "claude.weekly", provider: provider, title: "Weekly"),
            .percent(id: "claude.sonnet", provider: provider, title: "Sonnet"),
            .boundedDollars(id: "claude.extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage spent", limit: 100, valueWord: "spent"),
            .usageTrend(provider: provider)
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func refresh() async -> ProviderSnapshot {
        let candidates = await loadOffMainActor { [authStore] in authStore.loadCredentialCandidates() }
            .filter { $0.oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        guard !candidates.isEmpty else {
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

        if authStore.canFetchLiveUsage(state) {
            mapped = try await fetchLiveUsage(state: &state)
        }

        await SpendTileMapper.appendCcusageUsage(
            using: ccusageRunner, provider: .claude, homePath: authStore.claudeHomeOverride(),
            to: &mapped.lines, now: now()
        )

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
    }

    private func fetchLiveUsage(state: inout ClaudeCredentialState) async throws -> ClaudeMappedUsage {
        // Inside an active rate-limit cooldown, skip the live call and serve the last-good usage so a
        // constantly-limited endpoint doesn't blank the dashboard (and we don't pile on more 429s).
        if let until = rateLimitedUntil, now() < until {
            AppLog.info(LogTag.plugin("claude"), "rate-limited (cooldown active, serving \(lastGoodUsage == nil ? "badge" : "last-good usage"))")
            return rateLimitedSnapshot(credentials: state.oauth, retryAfterSeconds: Int(until.timeIntervalSince(now()).rounded(.up)))
        }

        if authStore.needsRefresh(state.oauth),
           let refreshToken = state.oauth.refreshToken,
           !refreshToken.isEmpty {
            state.oauth.accessToken = try await refreshAccessToken(state: &state, refreshToken: refreshToken)
        }

        var working = state
        defer { state = working }
        let response = try await ProviderAuthRetry.fetch(
            token: working.oauth.accessToken ?? "",
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0, config: self.authStore.oauthConfig()) },
            refreshAccessToken: {
                guard let refreshToken = working.oauth.refreshToken, !refreshToken.isEmpty else {
                    throw ClaudeAuthError.tokenExpired
                }
                return try await self.refreshAccessToken(state: &working, refreshToken: refreshToken)
            },
            connectionFailed: ClaudeUsageError.connectionFailed,
            authExpired: ClaudeAuthError.tokenExpired
        )

        // 429 can come back from either attempt; the helper hands both through unchanged. Start a cooldown
        // (respecting Retry-After) and serve the last-good usage rather than a bare badge.
        if response.statusCode == 429 {
            let retryAfterSeconds = ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now())
            rateLimitedUntil = now().addingTimeInterval(TimeInterval(retryAfterSeconds ?? Int(Self.rateLimitCooldown)))
            AppLog.info(LogTag.plugin("claude"), "rate-limited (serving \(lastGoodUsage == nil ? "badge" : "last-good usage"))")
            return rateLimitedSnapshot(credentials: working.oauth, retryAfterSeconds: retryAfterSeconds)
        }

        let mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: working.oauth, now: now())
        lastGoodUsage = mapped
        rateLimitedUntil = nil
        return mapped
    }

    /// Last-good usage with an appended staleness note when we have it; otherwise the plain rate-limited
    /// badge (no successful fetch yet this run). `lastGoodUsage` only ever holds a clean `mapUsageResponse`
    /// result (never a rate-limited snapshot), so the note is never duplicated and no stale ccusage tiles
    /// ride along — `probe` appends those fresh after this returns.
    private func rateLimitedSnapshot(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        guard var mapped = lastGoodUsage else {
            return ClaudeUsageMapper.rateLimitedUsage(credentials: credentials, retryAfterSeconds: retryAfterSeconds)
        }
        mapped.lines.append(ClaudeUsageMapper.rateLimitedNote(retryAfterSeconds: retryAfterSeconds))
        return mapped
    }

    private func refreshAccessToken(state: inout ClaudeCredentialState, refreshToken: String) async throws -> String {
        AppLog.info(LogTag.auth("claude"), "token refresh attempt")
        let response = try await usageClient.refreshToken(refreshToken, config: authStore.oauthConfig())
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
            throw ClaudeUsageError.requestFailed(response.statusCode)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeUsageError.requestFailed(response.statusCode)
        }
        // NEVER log decoded.accessToken / refreshToken — only the fact that a rotation happened.
        let decoded = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: response.body)
        state.oauth.accessToken = decoded.accessToken
        if let refreshToken = decoded.refreshToken {
            state.oauth.refreshToken = refreshToken
        }
        if let expiresIn = decoded.expiresIn {
            state.oauth.expiresAt = now().timeIntervalSince1970 * 1000 + expiresIn * 1000
        }
        // Fail loudly: a swallowed save leaves the OLD refresh token on disk after a rotation, so the
        // next launch refreshes with a server-invalidated token and the user sees a misleading
        // "session expired". The refreshed token still works for this session, so we log and continue
        // rather than fail the live fetch.
        do {
            try authStore.save(state)
        } catch {
            AppLog.error(LogTag.auth("claude"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        AppLog.info(LogTag.auth("claude"), "token refresh ok (rotated)")
        return decoded.accessToken
    }

}

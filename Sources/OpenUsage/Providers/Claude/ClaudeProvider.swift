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

    /// Last successful live-usage result and a rate-limit cooldown, carried across refreshes (the provider
    /// is a long-lived singleton). `/api/oauth/usage` rate-limits aggressively, so on a 429 we serve the
    /// last-good bars with a staleness note instead of blanking the dashboard, and skip the live call
    /// entirely until the cooldown expires so we don't keep hammering an endpoint that's already limiting
    /// us. Mirrors the legacy plugin's `cachedUsageData` + `rateLimitedUntilMs`.
    private var cachedCredentialFingerprint: Data?
    private var lastGoodUsage: ClaudeMappedUsage?
    private var rateLimitedUntil: Date?
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
            .percent(id: "claude.session", provider: provider, title: "Session", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "claude.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "claude.sonnet", provider: provider, title: "Sonnet")
                .exportingLimit("sonnet", unit: "percent"),
            .percent(id: "claude.fable", provider: provider, title: "Fable")
                .exportingLimit("fable", unit: "percent"),
            .boundedDollars(id: "claude.extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage spent", limit: 100, valueWord: "spent")
                .exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars)),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Claude usage history (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Never trigger another app's Keychain prompt during first-run detection. Encrypted Desktop
        // material still counts as a local login; the first manual refresh requests access if needed.
        let load = await loadOffMainActor { [authStore] in authStore.loadCredentialSet() }
        if load.candidates.contains(where: \.hasUsableAccessToken) { return true }
        return load.desktopStatus == .permissionRequired || load.desktopStatus == .stale
    }

    func refresh() async -> ProviderSnapshot {
        await refresh(
            credentialReloadsRemaining: 1,
            forceDesktopFallback: false,
            previousFallbackError: nil
        )
    }

    /// Claude Code can replace a login while a request is in flight. Reload once when that happens so
    /// the older account cannot reach the dashboard or cache; bound the retry for a changing source.
    private func refresh(
        credentialReloadsRemaining: Int,
        forceDesktopFallback: Bool,
        previousFallbackError: ClaudeAuthError?
    ) async -> ProviderSnapshot {
        let allowDesktopInteraction = ProviderRefreshContext.isManual
        let credentialLoad = await loadOffMainActor { [authStore] in
            authStore.loadCredentialSet(
                allowDesktopInteraction: allowDesktopInteraction,
                forceDesktopFallback: forceDesktopFallback
            )
        }
        let storedCandidates = credentialLoad.candidates
        let candidates = storedCandidates.filter {
            $0.hasUsableAccessToken && (!forceDesktopFallback || $0.source == .desktop)
        }
        if forceDesktopFallback {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopPermissionRequired)
            case .stale, .invalid, .notFound:
                if let previousFallbackError {
                    return ProviderSnapshot.error(provider: provider, error: previousFallbackError)
                }
            case .notChecked, .available:
                break
            }
        }
        let hasLiveUsageCandidate = candidates.contains {
            authStore.liveUsageAvailability($0) == .available
        }
        let desktopFallbackWarning: String? = if !hasLiveUsageCandidate {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                ClaudeAuthError.desktopPermissionRequired.localizedDescription
            case .stale:
                ClaudeAuthError.desktopTokenExpired.localizedDescription
            case .invalid:
                ClaudeAuthError.desktopCredentialsUnavailable.localizedDescription
            case .notChecked, .notFound, .available:
                nil
            }
        } else {
            nil
        }
        guard !candidates.isEmpty else {
            switch credentialLoad.desktopStatus {
            case .permissionRequired:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopPermissionRequired)
            case .stale:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopTokenExpired)
            case .invalid:
                return ProviderSnapshot.error(provider: provider, error: ClaudeAuthError.desktopCredentialsUnavailable)
            case .notChecked, .notFound, .available:
                break
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
        var lastFallbackError: ClaudeAuthError?
        var credentialGeneration = ClaudeCredentialGeneration(storedCandidates)
        for state in candidates {
            // The environment token cannot read subscription usage. If a CLI login was rejected, try
            // Desktop before this spend-only fallback can turn the refresh into a false success.
            if !forceDesktopFallback,
               lastFallbackError != nil,
               credentialLoad.desktopStatus == .notChecked,
               authStore.liveUsageAvailability(state) == .inferenceOnlyToken
            {
                return await refresh(
                    credentialReloadsRemaining: credentialReloadsRemaining,
                    forceDesktopFallback: true,
                    previousFallbackError: lastFallbackError
                )
            }
            do {
                let snapshot = try await probe(
                    state: state,
                    credentialGeneration: &credentialGeneration,
                    fallbackWarning: desktopFallbackWarning
                )
                AppLog.info(LogTag.plugin("claude"), "refresh end (\(Int(Date().timeIntervalSince(start) * 1000))ms)")
                return snapshot
            } catch ClaudeAuthError.credentialsChanged where credentialReloadsRemaining > 0 {
                AppLog.info(LogTag.auth("claude"), "credential source changed during refresh; reloading current login")
                return await refresh(
                    credentialReloadsRemaining: credentialReloadsRemaining - 1,
                    forceDesktopFallback: forceDesktopFallback,
                    previousFallbackError: previousFallbackError
                )
            } catch let error as ClaudeAuthError where error.allowsAuthFallback {
                AppLog.warn(LogTag.auth("claude"), "\(state.source.label) failed (\(error)); falling back to next source if any")
                lastFallbackError = error
                continue
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }
        if !forceDesktopFallback,
           lastFallbackError != nil,
           credentialLoad.desktopStatus == .notChecked
        {
            AppLog.info(LogTag.auth("claude"), "stored Claude login failed; trying Claude Desktop")
            return await refresh(
                credentialReloadsRemaining: credentialReloadsRemaining,
                forceDesktopFallback: true,
                previousFallbackError: lastFallbackError
            )
        }
        return ProviderSnapshot.error(
            provider: provider,
            error: lastFallbackError ?? ClaudeAuthError.notLoggedIn
        )
    }

    private func probe(
        state initialState: ClaudeCredentialState,
        credentialGeneration: inout ClaudeCredentialGeneration,
        fallbackWarning: String?
    ) async throws -> ProviderSnapshot {
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
            mapped = try await fetchLiveUsage(
                state: &state,
                credentialGeneration: &credentialGeneration
            )
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
        if let fallbackWarning {
            warning = fallbackWarning
        }

        // Local spend tiles, scanned natively from Claude Code's session logs and priced through the
        // shared pricing store, merged with Claude usage that happened inside pi (attributed back here).
        // Both scans run on their scanner actors, off the main actor.
        let pricing = await pricing()
        let nativeScan = await logUsageScanner.scan(now: now(), pricing: pricing)
        let piScan = await PiUsageScanner.shared.scan(cardID: provider.id, now: now(), pricing: pricing)
        var usageHistory: ProviderUsageHistory?
        if let scan = DailyUsageAccumulator.merged([nativeScan, piScan]) {
            let note = piScan == nil
                ? "From your Claude usage history (estimated)"
                : "From your Claude usage history and pi (estimated)"
            usageHistory = ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay
            )
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &mapped.lines, now: now(),
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: note
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &mapped.lines, now: now(), note: note)
        }

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now(),
            usageHistory: usageHistory,
            warning: warning
        )
    }

    private func fetchLiveUsage(
        state: inout ClaudeCredentialState,
        credentialGeneration: inout ClaudeCredentialGeneration
    ) async throws -> ClaudeMappedUsage {
        var expectedGeneration = credentialGeneration
        defer { credentialGeneration = expectedGeneration }
        activateLiveUsageCache(for: state.oauth)

        // Inside an active rate-limit cooldown, skip the live call and serve the last-good usage so a
        // constantly-limited endpoint doesn't blank the dashboard (and we don't pile on more 429s).
        if let until = rateLimitedUntil, now() < until {
            AppLog.info(LogTag.plugin("claude"), "rate-limited (cooldown active, serving \(lastGoodUsage == nil ? "badge" : "last-good usage"))")
            return rateLimitedSnapshot(credentials: state.oauth, retryAfterSeconds: Int(until.timeIntervalSince(now()).rounded(.up)))
        }

        if authStore.needsRefresh(state.oauth),
           let refreshToken = state.oauth.refreshToken,
           !refreshToken.isEmpty {
            let refreshed = try await refreshAccessToken(
                state: &state,
                refreshToken: refreshToken,
                expectedGeneration: expectedGeneration
            )
            state.oauth.accessToken = refreshed.accessToken
            if refreshed.persisted { expectedGeneration = expectedGeneration.replacing(state) }
        }

        var working = state
        defer { state = working }
        let response = try await ProviderAuthRetry.fetch(
            token: working.oauth.accessToken ?? "",
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0, config: self.authStore.oauthConfig()) },
            refreshAccessToken: {
                if working.source == .desktop {
                    throw ClaudeAuthError.desktopTokenExpired
                }
                guard let refreshToken = working.oauth.refreshToken, !refreshToken.isEmpty else {
                    throw ClaudeAuthError.tokenExpired
                }
                let refreshed = try await self.refreshAccessToken(
                    state: &working,
                    refreshToken: refreshToken,
                    expectedGeneration: expectedGeneration
                )
                if refreshed.persisted {
                    expectedGeneration = expectedGeneration.replacing(working)
                }
                return refreshed.accessToken
            },
            connectionFailed: ClaudeUsageError.connectionFailed,
            authExpired: ClaudeAuthError.tokenExpired
        )

        let forceDesktopGeneration = working.source == .desktop
        let currentGeneration = await loadOffMainActor { [authStore] in
            authStore.credentialGeneration(forceDesktopFallback: forceDesktopGeneration)
        }
        guard currentGeneration == expectedGeneration else { throw ClaudeAuthError.credentialsChanged }

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
    /// result (never a rate-limited snapshot), so the note is never duplicated and no stale spend tiles
    /// ride along — `probe` appends those fresh after this returns.
    private func rateLimitedSnapshot(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        guard var mapped = lastGoodUsage else {
            return ClaudeUsageMapper.rateLimitedUsage(credentials: credentials, retryAfterSeconds: retryAfterSeconds)
        }
        mapped.lines.append(ClaudeUsageMapper.rateLimitedNote(retryAfterSeconds: retryAfterSeconds))
        mapped.warning = ClaudeUsageMapper.rateLimitedWarning(retryAfterSeconds: retryAfterSeconds)
        return mapped
    }

    /// Cache state belongs to the complete access + refresh credential pair. A login change therefore
    /// clears both last-good usage and cooldown, even when the two accounts share an access token.
    private func activateLiveUsageCache(for credentials: ClaudeOAuth) {
        let fingerprint = Self.credentialFingerprint(credentials)
        guard cachedCredentialFingerprint != fingerprint else { return }
        cachedCredentialFingerprint = fingerprint
        lastGoodUsage = nil
        rateLimitedUntil = nil
    }

    private static func credentialFingerprint(_ credentials: ClaudeOAuth) -> Data {
        let access = Data((credentials.accessToken ?? "").utf8)
        let refresh = Data((credentials.refreshToken ?? "").utf8)
        var pair = Data(SHA256.hash(data: access))
        pair.append(contentsOf: SHA256.hash(data: refresh))
        return Data(SHA256.hash(data: pair))
    }

    private struct RefreshedAccess {
        var accessToken: String
        var persisted: Bool
    }

    private func refreshAccessToken(
        state: inout ClaudeCredentialState,
        refreshToken: String,
        expectedGeneration: ClaudeCredentialGeneration
    ) async throws -> RefreshedAccess {
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
        let previousOAuth = state.oauth
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
        let persisted: Bool
        do {
            guard try await Task.detached(priority: .utility, operation: { [authStore, state] in
                try authStore.save(state, ifUnchanged: expectedGeneration)
            }).value else {
                throw ClaudeAuthError.credentialsChanged
            }
            persisted = true
        } catch let error as ClaudeAuthError where error == .credentialsChanged {
            throw error
        } catch {
            AppLog.error(LogTag.auth("claude"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
            persisted = false
        }
        if cachedCredentialFingerprint == Self.credentialFingerprint(previousOAuth) {
            cachedCredentialFingerprint = Self.credentialFingerprint(state.oauth)
        }
        AppLog.info(LogTag.auth("claude"), "token refresh ok (rotated)")
        return RefreshedAccess(accessToken: decoded.accessToken, persisted: persisted)
    }

}

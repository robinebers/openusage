import Foundation

@MainActor
final class ClaudeProvider: ProviderRuntime {
    let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))

    let authStore: ClaudeAuthStore
    let usageClient: ClaudeUsageClient
    let ccusageRunner: CcusageRunner
    let now: @Sendable () -> Date

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
            .boundedDollars(id: "claude.extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage spent", limit: 100)
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func refresh() async -> ProviderSnapshot {
        guard let state = authStore.loadCredentials(),
              state.oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            AppLog.info(LogTag.auth("claude"), "no access token, not logged in")
            return ProviderSnapshot.error(provider: provider, message: ClaudeAuthError.notLoggedIn.localizedDescription)
        }

        AppLog.info(LogTag.plugin("claude"), "refresh start")
        let start = Date()
        do {
            let snapshot = try await probe(state: state)
            AppLog.info(LogTag.plugin("claude"), "refresh end (\(Int(Date().timeIntervalSince(start) * 1000))ms)")
            return snapshot
        } catch {
            return ProviderSnapshot.error(provider: provider, message: error.localizedDescription)
        }
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

        let since = CcusageRunner.sinceString(daysBack: 30, from: now())
        let tokenUsage = await ccusageRunner.query(provider: .claude, since: since, homePath: authStore.claudeHomeOverride())
        if case .success(let usage) = tokenUsage {
            SpendTileMapper.appendTokenUsage(usage, to: &mapped.lines, now: now())
        }

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now()
        )
    }

    private func fetchLiveUsage(state: inout ClaudeCredentialState) async throws -> ClaudeMappedUsage {
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

        // 429 can come back from either attempt; the helper hands both through unchanged.
        if response.statusCode == 429 {
            AppLog.info(LogTag.plugin("claude"), "rate-limited")
            return ClaudeUsageMapper.rateLimitedUsage(
                credentials: working.oauth,
                retryAfterSeconds: ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now())
            )
        }
        return try ClaudeUsageMapper.mapUsageResponse(response, credentials: working.oauth, now: now())
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
            throw ClaudeAuthError.tokenExpired
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
        try? authStore.save(state)
        AppLog.info(LogTag.auth("claude"), "token refresh ok (rotated)")
        return decoded.accessToken
    }

}


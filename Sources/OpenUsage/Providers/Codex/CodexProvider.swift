import Foundation

@MainActor
final class CodexProvider: ProviderRuntime {
    let provider = Provider(
        id: "codex",
        displayName: "Codex",
        icon: .providerMark("codex"),
        links: [
            .init(label: "Status", url: "https://status.openai.com/"),
            .init(label: "Dashboard", url: "https://chatgpt.com/codex/settings/usage")
        ]
    )

    let authStore: CodexAuthStore
    let usageClient: CodexUsageClient
    let ccusageRunner: CcusageRunner
    let now: @Sendable () -> Date

    init(
        authStore: CodexAuthStore = CodexAuthStore(),
        usageClient: CodexUsageClient = CodexUsageClient(),
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
            .percent(id: "codex.session", provider: provider, title: "Session"),
            .percent(id: "codex.weekly", provider: provider, title: "Weekly"),
            .combined(id: "codex.credits", provider: provider, title: "Extra Usage", metricLabel: "Credits"),
            .values(id: "codex.rateLimitResets", provider: provider, title: "Rate Limit Resets", metricLabel: "Rate Limit Resets"),
            .usageTrend(provider: provider)
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func refresh() async -> ProviderSnapshot {
        let (fileCandidates, _) = authStore.loadAuthCandidates()
        var lastFallbackError: Error?

        for candidate in fileCandidates {
            do {
                return try await probe(authState: candidate)
            } catch let error as CodexAuthError where error.allowsAuthFallback {
                lastFallbackError = error
                continue
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }

        if let keychainCandidate = await loadOffMainActor({ [authStore] in authStore.loadKeychainAuth() }) {
            do {
                return try await probe(authState: keychainCandidate)
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }

        if let lastFallbackError {
            return ProviderSnapshot.error(provider: provider, error: lastFallbackError)
        }
        return ProviderSnapshot.error(provider: provider, error: CodexAuthError.notLoggedIn)
    }

    private func probe(authState initialState: CodexAuthState) async throws -> ProviderSnapshot {
        var authState = initialState
        guard var accessToken = authState.auth.tokens?.accessToken, !accessToken.isEmpty else {
            if authState.auth.apiKey?.isEmpty == false {
                throw CodexAuthError.usageAPIKey
            }
            throw CodexAuthError.notLoggedIn
        }

        if authStore.needsRefresh(authState.auth),
           let refreshToken = authState.auth.tokens?.refreshToken,
           !refreshToken.isEmpty {
            let refreshed = try await refreshAccessToken(authState: &authState, refreshToken: refreshToken)
            accessToken = refreshed
        }

        let response = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        // The access token may have rotated during the usage fetch's refresh-and-retry; read the live one.
        let currentToken = authState.auth.tokens?.accessToken ?? accessToken
        let resetCredits = await fetchResetCreditsBestEffort(
            accessToken: currentToken,
            accountID: authState.auth.tokens?.accountID
        )
        var mapped = try CodexUsageMapper.mapUsageResponse(response, resetCredits: resetCredits, now: now())

        await SpendTileMapper.appendCcusageUsage(
            using: ccusageRunner, provider: .codex, homePath: authStore.codexHome(),
            to: &mapped.lines, now: now()
        )

        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
    }

    /// Fetches the on-demand reset-credit balance (and per-credit expiry) without ever failing the
    /// refresh: this is supplementary to the usage metrics, so a network error, timeout, or non-2xx just
    /// yields `nil` and the mapper falls back to the count embedded in the usage body. Logged, not thrown —
    /// the user still gets Session/Weekly/Credits even if this endpoint is down.
    private func fetchResetCreditsBestEffort(accessToken: String, accountID: String?) async -> HTTPResponse? {
        do {
            return try await usageClient.fetchResetCredits(accessToken: accessToken, accountID: accountID)
        } catch {
            AppLog.warn(LogTag.plugin("codex"), "reset-credit fetch failed; using usage-body count: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchUsageWithRetry(accessToken: String, authState: inout CodexAuthState) async throws -> HTTPResponse {
        var working = authState
        defer { authState = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0, accountID: working.auth.tokens?.accountID) },
            refreshAccessToken: {
                guard let refreshToken = working.auth.tokens?.refreshToken, !refreshToken.isEmpty else {
                    throw CodexAuthError.tokenExpired
                }
                do {
                    return try await self.refreshAccessToken(authState: &working, refreshToken: refreshToken)
                } catch let error as CodexAuthError {
                    throw error
                } catch {
                    throw CodexUsageError.connectionFailed
                }
            },
            connectionFailed: CodexUsageError.connectionFailed,
            authExpired: CodexAuthError.tokenExpired
        )
    }

    private func refreshAccessToken(authState: inout CodexAuthState, refreshToken: String) async throws -> String {
        let response = try await usageClient.refreshToken(refreshToken)
        authState.auth.tokens?.accessToken = response.accessToken
        if let refreshToken = response.refreshToken {
            authState.auth.tokens?.refreshToken = refreshToken
        }
        if let idToken = response.idToken {
            authState.auth.tokens?.idToken = idToken
        }
        authState.auth.lastRefresh = OpenUsageISO8601.string(from: now())
        // Fail loudly: a swallowed save strands the rotated token on disk (next launch re-refreshes /
        // can surface a false "token expired"). The refreshed token works for this session, so log and
        // continue. This is also the only call site of authStore.save, so a genuinely undecodable
        // payload (CodexAuthError.invalidAuthPayload) now surfaces in the log instead of vanishing.
        do {
            try authStore.save(authState)
        } catch {
            AppLog.error(LogTag.auth("codex"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        return response.accessToken
    }
}

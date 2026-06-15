import Foundation

@MainActor
final class CodexProvider: ProviderRuntime {
    let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))

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
            .verbatimDollars(id: "codex.credits", provider: provider, title: "Extra Usage", metricLabel: "Credits"),
            .spend(id: "codex.today", provider: provider, title: "Today", estimated: true),
            .spend(id: "codex.yesterday", provider: provider, title: "Yesterday", estimated: true),
            .spend(id: "codex.last30", provider: provider, title: "Last 30 Days", estimated: true)
        ]
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
                return ProviderSnapshot.error(provider: provider, message: error.localizedDescription)
            }
        }

        if let keychainCandidate = authStore.loadKeychainAuth() {
            do {
                return try await probe(authState: keychainCandidate)
            } catch {
                return ProviderSnapshot.error(provider: provider, message: error.localizedDescription)
            }
        }

        if let lastFallbackError {
            return ProviderSnapshot.error(provider: provider, message: lastFallbackError.localizedDescription)
        }
        return ProviderSnapshot.error(provider: provider, message: CodexAuthError.notLoggedIn.localizedDescription)
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
        var mapped = try CodexUsageMapper.mapUsageResponse(response, now: now())

        let since = CcusageRunner.sinceString(daysBack: 30, from: now())
        let tokenUsage = await ccusageRunner.query(provider: .codex, since: since, homePath: authStore.codexHome())
        if case .success(let usage) = tokenUsage {
            CcusageSpendMapper.appendTokenUsage(usage, to: &mapped.lines, now: now())
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
        try? authStore.save(authState)
        return response.accessToken
    }
}

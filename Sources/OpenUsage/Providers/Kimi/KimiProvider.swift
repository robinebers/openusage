import Foundation

@MainActor
final class KimiProvider: ProviderRuntime {
    let provider = Provider(
        id: "kimi",
        displayName: "Kimi Code",
        icon: .providerMark("kimi"),
        links: [
            ProviderLink(label: "Console", url: "https://www.kimi.com/code/console"),
            ProviderLink(label: "Docs", url: "https://www.kimi.com/code/docs/en/")
        ]
    )

    let authStore: KimiAuthStore
    let usageClient: KimiUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: KimiAuthStore = KimiAuthStore(),
        usageClient: KimiUsageClient = KimiUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "kimi.session", provider: provider, title: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "kimi.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: a user-supplied API key, or the Kimi Code CLI's token file.
        await loadOffMainActor { [authStore] in
            authStore.loadAPIKey() != nil || authStore.loadOAuthState() != nil
        }
    }

    func refresh() async -> ProviderSnapshot {
        // A user-supplied key (config file or environment) wins: it is the deliberate choice, it never
        // expires mid-cycle, and using it leaves the CLI's token file untouched.
        if let apiKey = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) {
            do {
                let response = try await usageClient.fetchUsage(token: apiKey)
                return try snapshot(from: response, authFailure: KimiAuthError.invalidKey)
            } catch let error as KimiAuthError {
                return ProviderSnapshot.error(provider: provider, error: error)
            } catch let error as KimiUsageError {
                return ProviderSnapshot.error(provider: provider, error: error)
            } catch {
                return ProviderSnapshot.error(provider: provider, error: KimiUsageError.connectionFailed)
            }
        }

        guard let oauthState = await loadOffMainActor({ [authStore] in authStore.loadOAuthState() }) else {
            return ProviderSnapshot.error(provider: provider, error: KimiAuthError.notLoggedIn)
        }
        do {
            return try await probe(oauthState: oauthState)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    // MARK: - CLI OAuth path

    private func probe(oauthState initialState: KimiOAuthState) async throws -> ProviderSnapshot {
        var state = initialState
        var accessToken = state.credentials.accessToken ?? ""

        if authStore.needsRefresh(state.credentials) {
            // The CLI may have rotated the token on disk since we loaded it. Re-read the live file and
            // adopt its newer token first — refreshing our stale copy would burn a rotated refresh
            // token for nothing.
            if let live = await loadOffMainActor({ [authStore, path = state.path] in authStore.loadOAuth(at: path) }) {
                state = live
                accessToken = live.credentials.accessToken ?? accessToken
            }
        }

        if authStore.needsRefresh(state.credentials) {
            guard let refreshToken = state.credentials.refreshToken, !refreshToken.isEmpty else {
                throw KimiAuthError.sessionExpired
            }
            accessToken = try await refreshAccessToken(state: &state, refreshToken: refreshToken)
        }
        guard !accessToken.isEmpty else {
            throw KimiAuthError.sessionExpired
        }

        let response = try await fetchUsageWithRetry(accessToken: accessToken, state: &state)
        return try snapshot(from: response, authFailure: KimiAuthError.sessionExpired)
    }

    private func fetchUsageWithRetry(accessToken: String, state: inout KimiOAuthState) async throws -> HTTPResponse {
        var working = state
        defer { state = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(token: $0) },
            refreshAccessToken: {
                guard let refreshToken = working.credentials.refreshToken, !refreshToken.isEmpty else {
                    throw KimiAuthError.sessionExpired
                }
                do {
                    return try await self.refreshAccessToken(state: &working, refreshToken: refreshToken)
                } catch let error as KimiAuthError {
                    throw error
                } catch let error as KimiUsageError {
                    throw error
                } catch {
                    throw KimiUsageError.connectionFailed
                }
            },
            connectionFailed: KimiUsageError.connectionFailed,
            authExpired: KimiAuthError.sessionExpired
        )
    }

    private func refreshAccessToken(state: inout KimiOAuthState, refreshToken: String) async throws -> String {
        let response = try await usageClient.refreshToken(refreshToken)
        state.credentials.accessToken = response.accessToken
        if let refreshToken = response.refreshToken {
            state.credentials.refreshToken = refreshToken
        }
        if let expiresIn = response.expiresIn {
            state.credentials.expiresAt = now().timeIntervalSince1970 + expiresIn
            state.credentials.expiresIn = expiresIn
        }
        if let scope = response.scope {
            state.credentials.scope = scope
        }
        if let tokenType = response.tokenType {
            state.credentials.tokenType = tokenType
        }
        // Fail loudly: a swallowed save strands the rotated refresh token in memory — the CLI's file
        // would keep the burnt one and the next sign-in check would fail. The refreshed access token
        // still works for this session, so log and continue.
        do {
            try authStore.save(state)
        } catch {
            AppLog.error(
                LogTag.auth("kimi"),
                "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)"
            )
        }
        return response.accessToken
    }

    private func snapshot(from response: HTTPResponse, authFailure: KimiAuthError) throws -> ProviderSnapshot {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: authFailure,
            requestFailed: { KimiUsageError.requestFailed($0) }
        )
        let mapped = try KimiUsageMapper.map(response.body)
        return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
    }
}

extension KimiProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.loadAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

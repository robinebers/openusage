import Foundation

@MainActor
final class KimiProvider: ProviderRuntime {
    let provider = Provider(
        id: "kimi",
        displayName: "Kimi",
        icon: .providerMark("kimi"),
        links: [
            .init(label: "Dashboard", url: "https://www.kimi.com/coding")
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
            .percent(id: "kimi.session", provider: provider, title: "Session", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "kimi.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`, existence-only: a blocking disk read, so it runs off the main actor.
        await loadOffMainActor { [authStore] in authStore.hasCredentialsFile() }
    }

    func refresh() async -> ProviderSnapshot {
        let loaded: KimiAuthState?
        do {
            loaded = try await loadOffMainActor { [authStore] in try authStore.load() }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard let loaded else {
            return ProviderSnapshot.error(provider: provider, error: KimiAuthError.notLoggedIn)
        }

        do {
            return try await probe(authState: loaded)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func probe(authState initialState: KimiAuthState) async throws -> ProviderSnapshot {
        var authState = initialState
        var accessToken = authState.oauth.accessToken

        if authStore.needsRefresh(authState.oauth) {
            // The `kimi` CLI refreshes on its own schedule and may have rotated the token on disk since we
            // loaded it. Adopt the live credential first — refreshing our stale copy would send an
            // already-rotated refresh token, which the server treats as a replay and which would log the
            // user out of Kimi.
            let home = authState.home
            if let live = await loadOffMainActor({ [authStore] in authStore.reloadLive(home: home) }) {
                authState = live
                accessToken = live.oauth.accessToken
            }
        }

        // Access tokens live only ~15 minutes, so a pre-emptive refresh is the normal path rather than an
        // edge case; `ProviderAuthRetry` below is the reactive backstop for a token that went bad early.
        if authStore.needsRefresh(authState.oauth),
           let refreshToken = authStore.refreshToken(for: authState.oauth) {
            accessToken = try await refreshAccessToken(authState: &authState, refreshToken: refreshToken)
        }

        let response = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: KimiAuthError.tokenExpired,
            requestFailed: KimiUsageError.requestFailed
        )

        var mapped = try KimiUsageMapper.mapUsageResponse(response)
        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now()
        )
    }

    private func fetchUsageWithRetry(
        accessToken: String,
        authState: inout KimiAuthState
    ) async throws -> HTTPResponse {
        var working = authState
        defer { authState = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0) },
            refreshAccessToken: {
                guard let refreshToken = self.authStore.refreshToken(for: working.oauth) else {
                    throw KimiAuthError.tokenExpired
                }
                do {
                    return try await self.refreshAccessToken(authState: &working, refreshToken: refreshToken)
                } catch let error as KimiAuthError {
                    throw error
                } catch let error as KimiUsageError {
                    throw error
                } catch {
                    throw KimiUsageError.connectionFailed
                }
            },
            connectionFailed: KimiUsageError.connectionFailed,
            authExpired: KimiAuthError.tokenExpired
        )
    }

    private func refreshAccessToken(
        authState: inout KimiAuthState,
        refreshToken: String
    ) async throws -> String {
        AppLog.info(LogTag.auth("kimi"), "token refresh attempt")
        let response = try await usageClient.refreshToken(refreshToken)

        // NEVER log the token values — only that a rotation happened.
        authState.oauth.accessToken = response.accessToken
        if let rotated = response.refreshToken?.nilIfEmpty {
            authState.oauth.refreshToken = rotated
        }
        if let expiresIn = response.expiresIn {
            authState.oauth.expiresIn = expiresIn
            authState.oauth.expiresAt = now().timeIntervalSince1970 + expiresIn
        }
        if let scope = response.scope?.nilIfEmpty { authState.oauth.scope = scope }
        if let tokenType = response.tokenType?.nilIfEmpty { authState.oauth.tokenType = tokenType }

        // Fail loudly: a swallowed save leaves the OLD refresh token in the CLI's credentials file after the
        // server has already rotated it, which is exactly how the user gets logged out of Kimi on the next
        // attempt. The refreshed token still works for this session, so log and continue.
        do {
            let state = authState
            try await loadOffMainActor { [authStore] in try authStore.save(state) }
        } catch {
            AppLog.error(
                LogTag.auth("kimi"),
                "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)"
            )
        }
        AppLog.info(LogTag.auth("kimi"), "token refresh ok (rotated)")
        return response.accessToken
    }
}

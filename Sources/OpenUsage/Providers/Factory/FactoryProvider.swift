import Foundation

@MainActor
final class FactoryProvider: ProviderRuntime {
    let provider = Provider(
        id: "factory",
        displayName: "Droid",
        icon: .providerMark("factory"),
        links: [
            .init(label: "Dashboard", url: "https://app.factory.ai/analytics"),
            .init(label: "Usage", url: "https://app.factory.ai/settings/usage")
        ]
    )

    let authStore: FactoryAuthStore
    let usageClient: FactoryUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: FactoryAuthStore = FactoryAuthStore(),
        usageClient: FactoryUsageClient = FactoryUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "factory.session", provider: provider, title: "Session", metricLabel: "5-hour usage", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "factory.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly usage")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "factory.monthly", provider: provider, title: "Monthly", metricLabel: "Monthly usage")
                .exportingLimit("monthly", unit: "percent"),
            .dollarBalance(id: "factory.extra", provider: provider, title: "Extra Usage", metricLabel: "Extra Usage", valueWord: "left")
                .exportingLimit("extraUsageBalance", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .boundedCount(id: "factory.standard", provider: provider, title: "Standard", metricLabel: "Standard", limit: 1, suffix: "tokens")
                .exportingLimit("standardTokens", unit: "tokens"),
            .boundedCount(id: "factory.premium", provider: provider, title: "Premium", metricLabel: "Premium", limit: 1, suffix: "tokens")
                .exportingLimit("premiumTokens", unit: "tokens"),
            .badge(id: "factory.droidCore", provider: provider, title: "Droid Core", metricLabel: "Droid Core"),
            .boundedCount(id: "factory.managed", provider: provider, title: "Managed Computers", metricLabel: "Managed Computers", limit: 1, suffix: "h")
                .exportingLimit("managedComputers", unit: "hours")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.hasAnyCredentialSource() }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            return try await loadAndProbe()
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func loadAndProbe() async throws -> ProviderSnapshot {
        guard var state = await loadOffMainActor({ authStore.loadAuthState() }) else {
            throw FactoryAuthError.notLoggedIn
        }

        guard let initialAccessToken = state.auth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            throw FactoryAuthError.invalidCredentialData
        }

        var accessToken = initialAccessToken
        if authStore.needsRefresh(accessToken: accessToken) {
            if let refreshed = await refreshAccessToken(state: &state) {
                accessToken = refreshed
            } else if !authStore.accessTokenIsUsable(accessToken) {
                throw FactoryAuthError.sessionExpired
            }
        }

        let mapped = try await fetchMappedUsage(accessToken: accessToken, state: &state)
        return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
    }

    private func fetchMappedUsage(accessToken: String, state: inout FactoryAuthState) async throws -> FactoryMappedUsage {
        let userID = authStore.userID(from: accessToken)
        let response = try await fetchUsageWithRetry(accessToken: accessToken, userID: userID, state: &state)
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: FactoryAuthError.sessionExpired,
            requestFailed: FactoryUsageError.requestFailed
        )

        guard let root = ProviderParse.jsonObject(response.body),
              var usage = root["usage"] as? [String: Any] else {
            throw FactoryUsageError.invalidResponse
        }

        let billingLimits = await fetchOptionalJSON(accessToken: accessToken) {
            try await usageClient.fetchBillingLimits(accessToken: $0)
        }
        let computeUsage = await fetchOptionalJSON(accessToken: accessToken) {
            try await usageClient.fetchComputeUsage(accessToken: $0)
        }
        usage = FactoryUsageMapper.mergeSupplementalUsage(
            usage: usage,
            rootData: root,
            billingLimits: billingLimits,
            computeUsage: computeUsage
        )
        return try FactoryUsageMapper.mapUsageResponse(usage: usage)
    }

    private func fetchUsageWithRetry(
        accessToken: String,
        userID: String?,
        state: inout FactoryAuthState
    ) async throws -> HTTPResponse {
        var working = state
        defer { state = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { token in
                try await self.usageClient.fetchSubscriptionUsage(accessToken: token, userID: userID)
            },
            refreshAccessToken: {
                guard let refreshed = await self.refreshAccessToken(state: &working) else {
                    throw FactoryAuthError.sessionExpired
                }
                return refreshed
            },
            connectionFailed: FactoryUsageError.connectionFailed,
            authExpired: FactoryAuthError.sessionExpired
        )
    }

    private func refreshAccessToken(state: inout FactoryAuthState) async -> String? {
        guard let refreshToken = state.auth.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }

        switch await usageClient.refreshToken(refreshToken) {
        case .refreshed(let accessToken, let rotatedRefresh):
            state.auth.accessToken = accessToken
            if let rotatedRefresh {
                state.auth.refreshToken = rotatedRefresh
            }
            do {
                try authStore.save(state)
            } catch {
                AppLog.error(
                    LogTag.auth("factory"),
                    "failed to persist rotated Droid credentials; using refreshed token for this session only: \(error.localizedDescription)"
                )
            }
            return accessToken
        case .authFailed:
            return nil
        case .unavailable:
            return nil
        }
    }

    private func fetchOptionalJSON(
        accessToken: String,
        request: (_ accessToken: String) async throws -> HTTPResponse
    ) async -> [String: Any]? {
        guard let response = try? await request(accessToken),
              (200..<300).contains(response.statusCode),
              let json = ProviderParse.jsonObject(response.body) else {
            return nil
        }
        return json
    }
}

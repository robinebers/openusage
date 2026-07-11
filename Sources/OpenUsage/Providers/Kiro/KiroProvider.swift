import Foundation

@MainActor
final class KiroProvider: ProviderRuntime {
    let provider = Provider(
        id: "kiro",
        displayName: "Kiro",
        icon: .providerMark("kiro"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://app.kiro.dev/account/usage"),
            ProviderLink(label: "Pricing", url: "https://kiro.dev/pricing/")
        ]
    )

    let authStore: KiroAuthStore
    let usageClient: KiroUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: KiroAuthStore = KiroAuthStore(),
        usageClient: KiroUsageClient = KiroUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedCount(id: "kiro.credits", provider: provider, title: "Credits",
                          metricLabel: "Credits", limit: 1000, suffix: "credits",
                          periodDurationMs: MetricPeriod.monthMs),
            .boundedCount(id: "kiro.bonus", provider: provider, title: "Bonus Credits",
                          metricLabel: "Bonus Credits", limit: 500, suffix: "credits",
                          periodDurationMs: MetricPeriod.monthMs),
            .badge(id: "kiro.overages", provider: provider, title: "Overages",
                   metricLabel: "Overages")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: the IDE token file, then the CLI SQLite database. Both are
        // blocking disk/SQLite reads, so both run off the main actor (see `loadOffMainActor`).
        if await loadOffMainActor({ [authStore] in authStore.loadTokenFile() }) != nil { return true }
        return await loadOffMainActor { [authStore] in authStore.loadCLIToken() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        // Try the IDE token file first (primary source).
        let tokenFileAuth = await loadOffMainActor { [authStore] in authStore.loadTokenFile() }

        if let auth = tokenFileAuth {
            return await refreshWithAuth(auth)
        }

        // Fall back to the kiro-cli SQLite database (last priority).
        let cliAuth = await loadOffMainActor { [authStore] in authStore.loadCLIToken() }

        if let auth = cliAuth {
            return await refreshWithAuth(auth)
        }

        return ProviderSnapshot.error(provider: provider, error: KiroAuthError.notLoggedIn)
    }

    // MARK: - Private

    private func refreshWithAuth(_ auth: KiroAuth) async -> ProviderSnapshot {
        // Resolve the profile ARN — required for the usage API.
        let profileArn = await loadOffMainActor { [authStore] in authStore.effectiveProfileArn(auth) }

        guard let profileArn else {
            return ProviderSnapshot.error(provider: provider, error: KiroAuthError.missingProfileArn)
        }

        // Try the usage API with the current access token.
        let result = await fetchUsage(accessToken: auth.accessToken, profileArn: profileArn, region: auth.region)

        switch result {
        case .success(let body):
            do {
                let mapped = try KiroUsageMapper.map(body)
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }

        case .authFailure:
            // Token expired — attempt a refresh, then retry once.
            guard let refreshed = await refreshToken(auth) else {
                return ProviderSnapshot.error(provider: provider, error: KiroUsageError.tokenRefreshFailed)
            }
            let retryResult = await fetchUsage(accessToken: refreshed.accessToken, profileArn: profileArn, region: auth.region)
            switch retryResult {
            case .success(let body):
                do {
                    let mapped = try KiroUsageMapper.map(body)
                    return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
                } catch {
                    return ProviderSnapshot.error(provider: provider, error: error)
                }
            case .authFailure:
                return ProviderSnapshot.error(provider: provider, error: KiroUsageError.tokenRefreshFailed)
            case .failed(let error):
                return ProviderSnapshot.error(provider: provider, error: error)
            }

        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private enum FetchResult {
        case success(Data)
        case authFailure
        case failed(KiroUsageError)
    }

    private func fetchUsage(accessToken: String, profileArn: String, region: String) async -> FetchResult {
        do {
            let response = try await usageClient.fetchUsageLimits(accessToken: accessToken, profileArn: profileArn, region: region)
            if response.statusCode == 401 || response.statusCode == 403 {
                return .authFailure
            }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }

    private func refreshToken(_ auth: KiroAuth) async -> KiroRefreshedToken? {
        guard let refreshToken = auth.refreshToken else { return nil }

        do {
            switch auth.authType {
            case .social:
                return try await usageClient.refreshSocialToken(refreshToken: refreshToken)
            case .oidc:
                guard let clientId = auth.clientId, let clientSecret = auth.clientSecret else {
                    return try await usageClient.refreshSocialToken(refreshToken: refreshToken)
                }
                return try await usageClient.refreshOIDCToken(
                    refreshToken: refreshToken,
                    clientId: clientId,
                    clientSecret: clientSecret,
                    region: auth.region
                )
            }
        } catch {
            return nil
        }
    }
}

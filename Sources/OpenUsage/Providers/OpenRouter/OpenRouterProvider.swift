import Foundation

@MainActor
final class OpenRouterProvider: ProviderRuntime {
    let provider = Provider(
        id: "openrouter",
        displayName: "OpenRouter",
        icon: .providerMark("openrouter"),
        links: [
            ProviderLink(label: "Activity", url: "https://openrouter.ai/activity"),
            ProviderLink(label: "Credits", url: "https://openrouter.ai/settings/credits")
        ]
    )

    let authStore: OpenRouterAuthStore
    let usageClient: OpenRouterUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: OpenRouterAuthStore = OpenRouterAuthStore(),
        usageClient: OpenRouterUsageClient = OpenRouterUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedDollars(id: "openrouter.credits", provider: provider, title: "Credits",
                            metricLabel: "Credits", limit: 100, limitNoun: "purchased")
                .exportingLimit("credits", unit: "usd"),
            .dollarBalance(id: "openrouter.balance", provider: provider, title: "Balance",
                           metricLabel: "Balance", valueWord: "left")
                .exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .values(id: "openrouter.today", provider: provider, title: "Today",
                    metricLabel: "Today", selection: .kind(.dollars), isUsagePeriod: true),
            .values(id: "openrouter.week", provider: provider, title: "This Week",
                    metricLabel: "This Week", selection: .kind(.dollars), isUsagePeriod: true),
            .values(id: "openrouter.month", provider: provider, title: "This Month",
                    metricLabel: "This Month", selection: .kind(.dollars), isUsagePeriod: true),
            .boundedDollars(id: "openrouter.keyLimit", provider: provider, title: "Key Limit",
                            metricLabel: "Key Limit", limit: 100, valueWord: "spent")
                .exportingLimit("keyLimit", unit: "usd")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: a stored or environment-exported API key.
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: OpenRouterAuthError.missingKey)
        }

        // Both endpoints are fetched independently and mapped from whatever succeeds. `/credits` carries
        // the balance and `/key` the tier + period spend; OpenRouter gates some endpoints to specific key
        // types, so one returning 403 must not blank out the data the other returned.
        let credits = await load { try await usageClient.fetchCredits(apiKey: auth.apiKey) }
        let key = await load { try await usageClient.fetchKey(apiKey: auth.apiKey) }

        var lines: [MetricLine] = []
        var plan: String?
        if case .success(let data) = credits {
            lines += OpenRouterUsageMapper.creditsLines(from: data)
        }
        if case .success(let data) = key {
            let mapped = OpenRouterUsageMapper.keyMetrics(from: data)
            plan = mapped.plan
            lines += mapped.lines
        }

        if !lines.isEmpty {
            return ProviderSnapshot.make(provider: provider, plan: plan, lines: lines, refreshedAt: now())
        }

        // Nothing usable came back. Only call the key invalid when BOTH endpoints rejected it
        // (401/403) — OpenRouter gates some endpoints to specific key types, so a single 403 (e.g.
        // `/credits` forbidden) while `/key` succeeded means the key is valid but gated, not invalid.
        if credits.isAuthFailure && key.isAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: OpenRouterAuthError.invalidKey)
        }
        let error = credits.failureError ?? key.failureError ?? OpenRouterUsageError.invalidResponse
        return ProviderSnapshot.error(provider: provider, error: error)
    }

    /// Run one endpoint call and classify the outcome: a parsed data object on 2xx, an auth failure on
    /// 401/403, or a typed failure for any other non-2xx, transport error, or unparsable body.
    private func load(_ call: () async throws -> HTTPResponse) async -> EndpointResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            guard let data = OpenRouterUsageMapper.dataObject(response.body) else {
                return .failed(.invalidResponse)
            }
            return .success(data)
        } catch {
            return .failed(.connectionFailed)
        }
    }
}

extension OpenRouterProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

private enum EndpointResult {
    case success([String: Any])
    case authFailure
    case failed(OpenRouterUsageError)

    var isAuthFailure: Bool {
        if case .authFailure = self { return true }
        return false
    }

    var failureError: OpenRouterUsageError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

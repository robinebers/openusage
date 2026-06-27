import Foundation

@MainActor
final class OpenRouterProvider: ProviderRuntime {
    let provider = Provider(id: "openrouter", displayName: "OpenRouter", icon: .providerMark("openrouter"))

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
                            metricLabel: "Credits", limit: 100, limitNoun: "purchased"),
            .dollarBalance(id: "openrouter.balance", provider: provider, title: "Balance",
                           metricLabel: "Balance", valueWord: "left"),
            .values(id: "openrouter.today", provider: provider, title: "Today",
                    metricLabel: "Today", selection: .kind(.dollars), isUsagePeriod: true),
            .values(id: "openrouter.week", provider: provider, title: "This Week",
                    metricLabel: "This Week", selection: .kind(.dollars), isUsagePeriod: true),
            .values(id: "openrouter.month", provider: provider, title: "This Month",
                    metricLabel: "This Month", selection: .kind(.dollars), isUsagePeriod: true),
            .boundedDollars(id: "openrouter.keyLimit", provider: provider, title: "Key Limit",
                            metricLabel: "Key Limit", limit: 100, valueWord: "spent")
        ]
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: OpenRouterAuthError.missingKey)
        }

        do {
            let credits = try await usageClient.fetchCredits(apiKey: auth.apiKey)
            // `/key` is best-effort enrichment (tier, period spend, per-key cap); a transport failure
            // here must not sink the snapshot, so swallow it and map from `/credits` alone.
            let keyResponse = try? await usageClient.fetchKey(apiKey: auth.apiKey)
            let mapped = try OpenRouterUsageMapper.map(creditsResponse: credits, keyResponse: keyResponse)
            return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
        } catch let error as OpenRouterAuthError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch let error as OpenRouterUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: OpenRouterUsageError.connectionFailed)
        }
    }
}

import Foundation

@MainActor
final class DeepSeekProvider: ProviderRuntime {
    let provider = Provider(
        id: "deepseek",
        displayName: "DeepSeek",
        icon: .providerMark("deepseek"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://platform.deepseek.com/usage"),
            ProviderLink(label: "API Keys", url: "https://platform.deepseek.com/api_keys")
        ]
    )

    let authStore: DeepSeekAuthStore
    let usageClient: DeepSeekUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: DeepSeekAuthStore = DeepSeekAuthStore(),
        usageClient: DeepSeekUsageClient = DeepSeekUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .dollarBalance(id: "deepseek.balance", provider: provider, title: "Balance",
                           metricLabel: "Balance", valueWord: "remaining")
                .exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: DeepSeekAuthError.missingKey)
        }

        do {
            let response = try await usageClient.fetchBalance(apiKey: auth.apiKey)
            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: DeepSeekAuthError.invalidKey)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(provider: provider, error: DeepSeekUsageError.requestFailed(response.statusCode))
            }
            let lines = DeepSeekUsageMapper.balanceLines(from: response.body)
            guard !lines.isEmpty else {
                return ProviderSnapshot.error(provider: provider, error: DeepSeekUsageError.invalidResponse)
            }
            return ProviderSnapshot.make(provider: provider, lines: lines, refreshedAt: now())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: DeepSeekUsageError.connectionFailed)
        }
    }
}

extension DeepSeekProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

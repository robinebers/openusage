import Foundation

@MainActor
final class DeepSeekProvider: ProviderRuntime {
    let provider = Provider(
        id: "deepseek", displayName: "DeepSeek", icon: .providerMark("deepseek"),
        links: [
            ProviderLink(label: "Status", url: "https://status.deepseek.com"),
            ProviderLink(label: "Dashboard", url: "https://platform.deepseek.com/usage")
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
            .dollarBalance(id: "deepseek.balance", provider: provider, title: "Balance", valueWord: "left")
                .exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .dollarBalance(id: "deepseek.paid", provider: provider, title: "Paid", valueWord: "left")
                .exportingLimit("paid", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .dollarBalance(id: "deepseek.granted", provider: provider, title: "Granted", valueWord: "left")
                .exportingLimit("granted", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let key = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return .error(provider: provider, error: DeepSeekAuthError.missingKey)
        }
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchBalance(apiKey: key)
        } catch {
            return .error(provider: provider, error: DeepSeekUsageError.connectionFailed)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            return .error(provider: provider, error: DeepSeekAuthError.invalidKey)
        }
        guard (200..<300).contains(response.statusCode) else {
            return .error(provider: provider, error: DeepSeekUsageError.requestFailed(response.statusCode))
        }
        do {
            let balance = try DeepSeekUsageMapper.balance(from: response.body)
            return .make(provider: provider, plan: nil, lines: balance.lines,
                         refreshedAt: now(), warning: balance.warning)
        } catch {
            return .error(provider: provider, error: error)
        }
    }
}

extension DeepSeekProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

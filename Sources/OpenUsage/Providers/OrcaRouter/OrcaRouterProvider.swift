import Foundation

@MainActor
final class OrcaRouterProvider: ProviderRuntime {
    let provider = Provider(
        id: "orcarouter",
        displayName: "OrcaRouter",
        icon: .providerMark("orcarouter"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://www.orcarouter.ai/console")
        ]
    )

    let authStore: OrcaRouterAuthStore
    let usageClient: OrcaRouterUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: OrcaRouterAuthStore = OrcaRouterAuthStore(),
        usageClient: OrcaRouterUsageClient = OrcaRouterUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .values(id: "orcarouter.totalUsage", provider: provider, title: "Total Usage",
                    metricLabel: "Total Usage", selection: .kind(.dollars), valueWord: "spent")
                .exportingLimit("totalUsage", unit: "usd", source: .value(kind: .dollars)),
            .dollarBalance(id: "orcarouter.balance", provider: provider, title: "Balance",
                           metricLabel: "Balance", valueWord: "left")
                .exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .values(id: "orcarouter.freeCredit", provider: provider, title: "Free Credit",
                    metricLabel: "Free Credit", selection: .kind(.dollars), valueWord: "left")
                .exportingLimit("freeCredit", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: a stored or environment-exported API key.
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: OrcaRouterAuthError.missingKey)
        }

        // Both endpoints are fetched independently and mapped from whatever succeeds. `/usage` carries
        // the workspace-wide spend and `/balance` the funded wallet + free credits; OrcaRouter can gate
        // either endpoint for a particular key type, so one returning 403 must not blank out the data
        // the other returned.
        let usage = await load { try await usageClient.fetchUsage(apiKey: auth.apiKey) }
        let balance = await load { try await usageClient.fetchBalance(apiKey: auth.apiKey) }

        var lines: [MetricLine] = []
        if case .success(let data) = usage, let line = OrcaRouterUsageMapper.usageLine(from: data) {
            lines.append(line)
        }
        if case .success(let data) = balance {
            lines += OrcaRouterUsageMapper.balanceLines(from: data)
        }

        if !lines.isEmpty {
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now())
        }

        // Nothing usable came back. Only call the key invalid when BOTH endpoints rejected it
        // (401/403) — OrcaRouter can gate either endpoint, so a single 403 (e.g. `/balance` forbidden)
        // while `/usage` succeeded means the key is valid but gated, not invalid.
        if usage.isAuthFailure && balance.isAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: OrcaRouterAuthError.invalidKey)
        }
        let error = usage.failureError ?? balance.failureError ?? OrcaRouterUsageError.invalidResponse
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
            guard let data = ProviderParse.jsonObject(response.body) else {
                return .failed(.invalidResponse)
            }
            return .success(data)
        } catch {
            return .failed(.connectionFailed)
        }
    }
}

extension OrcaRouterProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

private enum EndpointResult {
    case success([String: Any])
    case authFailure
    case failed(OrcaRouterUsageError)

    var isAuthFailure: Bool {
        if case .authFailure = self { return true }
        return false
    }

    var failureError: OrcaRouterUsageError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

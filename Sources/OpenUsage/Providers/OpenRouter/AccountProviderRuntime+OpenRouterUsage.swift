import Foundation

extension AccountProviderRuntime {
    func refreshOpenRouter(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let apiKey) = credential else { throw ProviderError.invalidResponse }
        let client = OpenRouterUsageClient(http: http)
        let key = try await client.key(apiKey: apiKey, now: now())
        switch key.kind {
        case .standard(let spend):
            let history = UsageHistory(calendar: OpenRouterUsageMapper.utc, asOf: now(), reported: spend)
            return ProviderUsage(plan: key.plan, lines: key.lines, history: history)
        case .management:
            let credits = try await client.creditsLines(apiKey: apiKey)
            let spend = try await client.listedKeysSpend(apiKey: apiKey)
            let source = OpenRouterActivitySource(client: client, apiKey: apiKey, accountID: account.cardID)
            var history = await refreshHistory(using: source) ?? UsageHistory(calendar: OpenRouterUsageMapper.utc, asOf: now())
            history.reported = spend
            return ProviderUsage(plan: key.plan, lines: credits + key.lines, history: history)
        }
    }
}

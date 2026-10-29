import Foundation

extension AccountProviderRuntime {
    func refreshOpenRouter(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let apiKey) = credential else { throw ProviderError.invalidResponse }
        let client = OpenRouterUsageClient(http: http)
        let key = try await client.key(apiKey: apiKey, now: now())
        switch key.kind {
        case .standard(let lines):
            return ProviderUsage(plan: key.plan, lines: lines)
        case .management:
            let credits = try await client.creditsLines(apiKey: apiKey)
            let spend = try await client.listedKeysSpend(apiKey: apiKey)
            return ProviderUsage(plan: key.plan, lines: credits + OpenRouterUsageMapper.spendLines(spend))
        }
    }
}

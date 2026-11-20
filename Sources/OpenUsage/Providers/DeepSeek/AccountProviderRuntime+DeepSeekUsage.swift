import Foundation

extension AccountProviderRuntime {
    func refreshDeepSeek(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let key) = credential else { throw unreadableCredential }
        let response = try await DeepSeekUsageClient(http: http).fetchBalance(apiKey: key)
        try ProviderError.requireSuccess(response, kind: .deepseek)
        return try DeepSeekUsageMapper.map(response.body)
    }
}

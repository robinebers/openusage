import Foundation

extension AccountProviderRuntime {
    private enum OpenRouterEndpoint {
        case data([String: Any])
        case keyRejected
        case failed(Error)
    }

    private func openRouterEndpoint(_ call: () async throws -> HTTPResponse) async -> OpenRouterEndpoint {
        do {
            let response = try await call()
            if ProviderError.isAuthFailure(response) { return .keyRejected }
            try ProviderError.requireSuccess(response, kind: .openrouter)
            guard let data = OpenRouterUsageMapper.dataObject(response.body) else {
                return .failed(ProviderError.invalidResponse)
            }
            return .data(data)
        } catch {
            return .failed(error)
        }
    }

    func refreshOpenRouter(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let key) = credential else { throw ProviderError.invalidResponse }
        let client = OpenRouterUsageClient(http: http)
        let credits = await openRouterEndpoint { try await client.fetchCredits(apiKey: key) }
        let keyInfo = await openRouterEndpoint { try await client.fetchKey(apiKey: key) }
        var lines: [MetricLine] = []
        var plan: String?
        if case .data(let data) = credits {
            lines += OpenRouterUsageMapper.creditsLines(from: data)
        }
        if case .data(let data) = keyInfo {
            let mapped = OpenRouterUsageMapper.keyMetrics(from: data)
            plan = mapped.plan
            lines += mapped.lines
        }
        if !lines.isEmpty { return ProviderUsage(plan: plan, lines: lines) }
        // The key is only invalid when both endpoints reject it: OpenRouter gates some endpoints to
        // specific key types, so a lone 403 is a valid key that cannot read that endpoint.
        if case .keyRejected = credits, case .keyRejected = keyInfo {
            throw ProviderError.signInExpired(.openrouter)
        }
        let failures = [credits, keyInfo].compactMap { outcome -> Error? in
            if case .failed(let error) = outcome { return error }
            return nil
        }
        throw failures.first ?? ProviderError.invalidResponse
    }
}

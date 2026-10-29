import Foundation

struct OpenRouterUsageClient: Sendable {
    static let creditsURL = "https://openrouter.ai/api/v1/credits"
    static let keyURL = "https://openrouter.ai/api/v1/key"
    static let keysURL = "https://openrouter.ai/api/v1/keys"
    static let keysPageSize = 100
    /// Bounds the page loop should OpenRouter ever ignore `offset`.
    static let maxKeysPages = 50

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func key(apiKey: String, now: Date) async throws -> OpenRouterKey {
        try OpenRouterUsageMapper.key(try await get(Self.keyURL, apiKey: apiKey), now: now)
    }

    func creditsLines(apiKey: String) async throws -> [MetricLine] {
        try OpenRouterUsageMapper.creditsLines(try await get(Self.creditsURL, apiKey: apiKey))
    }

    /// Disabled and expired keys count too: what they spent before they stopped is still this period's spend.
    func listedKeysSpend(apiKey: String) async throws -> OpenRouterSpend {
        var total = OpenRouterSpend.zero
        for page in 0..<Self.maxKeysPages {
            let url = "\(Self.keysURL)?include_disabled=true&include_expired=true&offset=\(page * Self.keysPageSize)"
            let keys = try OpenRouterUsageMapper.keysPage(try await get(url, apiKey: apiKey))
            total = keys.reduce(total, +)
            if keys.count < Self.keysPageSize { return total }
        }
        throw ProviderError.invalidResponse
    }

    private func get(_ urlString: String, apiKey: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw ProviderError.invalidResponse
        }

        let response = try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
        try ProviderError.requireSuccess(response, kind: .openrouter)
        return response.body
    }
}

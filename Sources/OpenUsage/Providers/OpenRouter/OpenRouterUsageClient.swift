import Foundation

struct OpenRouterUsageClient: Sendable {
    static let creditsURL = "https://openrouter.ai/api/v1/credits"
    static let keyURL = "https://openrouter.ai/api/v1/key"
    static let keysURL = "https://openrouter.ai/api/v1/keys"
    static let activityURL = "https://openrouter.ai/api/v1/activity"
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

    /// Empty for a Management key scoped to one workspace: OpenRouter bills credits per account and
    /// refuses such a key the account's credits with a 403.
    func creditsLines(apiKey: String) async throws -> [MetricLine] {
        let response = try await send(Self.creditsURL, apiKey: apiKey)
        if response.statusCode == 403 { return [] }
        try ProviderError.requireSuccess(response, kind: .openrouter)
        return try OpenRouterUsageMapper.creditsLines(response.body)
    }

    /// Disabled and expired keys count too: what they spent before they stopped is still this period's spend.
    func listedKeysSpend(apiKey: String) async throws -> [UsageWindow: UsageTotals] {
        var total = OpenRouterUsageMapper.noSpend
        for page in 0..<Self.maxKeysPages {
            let url = "\(Self.keysURL)?include_disabled=true&include_expired=true&offset=\(page * Self.keysPageSize)"
            let keys = try OpenRouterUsageMapper.keysPage(try await get(url, apiKey: apiKey))
            total = keys.reduce(total) { $0.merging($1) { $0.adding($1) } }
            if keys.count < Self.keysPageSize { return total }
        }
        throw ProviderError.invalidResponse
    }

    /// One UTC day when `date` is set, else the last 30 finished UTC days.
    func activity(apiKey: String, date: Date?) async throws -> HTTPResponse {
        let day = date.map { "?date=\($0.formatted(.iso8601.year().month().day()))" } ?? ""
        return try await send(Self.activityURL + day, apiKey: apiKey)
    }

    private func get(_ urlString: String, apiKey: String) async throws -> Data {
        let response = try await send(urlString, apiKey: apiKey)
        try ProviderError.requireSuccess(response, kind: .openrouter)
        return response.body
    }

    private func send(_ urlString: String, apiKey: String) async throws -> HTTPResponse {
        guard let url = URL(string: urlString) else {
            throw ProviderError.invalidResponse
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

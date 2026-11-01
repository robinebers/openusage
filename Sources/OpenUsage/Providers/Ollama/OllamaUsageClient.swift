import Foundation

struct OllamaUsageClient: Sendable {
    static let host = "https://ollama.com"
    static let balancePath = "/api/balance"
    static let accountPath = "/api/me"
    static let usagePath = "/api/usage"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchBalance(apiKey: String) async throws -> HTTPResponse {
        try await send(method: "GET", path: Self.balancePath, apiKey: apiKey)
    }

    /// `range` is 7d or 30d: whole UTC days back from today, plus today so far.
    func fetchUsage(apiKey: String, range: String) async throws -> HTTPResponse {
        try await send(method: "GET", path: Self.usagePath + "?range=\(range)&group_by=model", apiKey: apiKey)
    }

    func fetchAccount(apiKey: String) async throws -> HTTPResponse {
        try await send(method: "POST", path: Self.accountPath, apiKey: apiKey)
    }

    private func send(method: String, path: String, apiKey: String) async throws -> HTTPResponse {
        guard let url = URL(string: Self.host + path) else {
            throw ProviderError.invalidResponse
        }
        return try await http.send(HTTPRequest(
            method: method,
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

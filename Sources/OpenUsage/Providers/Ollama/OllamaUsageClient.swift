import Foundation

struct OllamaUsageClient: Sendable {
    static let host = "https://ollama.com"
    static let balancePath = "/api/balance"
    static let accountPath = "/api/me"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchBalance(apiKey: String) async throws -> HTTPResponse {
        try await send(method: "GET", path: Self.balancePath, apiKey: apiKey)
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

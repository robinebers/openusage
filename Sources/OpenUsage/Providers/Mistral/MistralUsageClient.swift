import Foundation

struct MistralUsageClient: Sendable {
    /// The subscription page's server-rendered payload carries both included allowances
    /// (`api_budget` / `vibe_budget`). Same-origin HTML page — cookies only, no CSRF header.
    static let subscriptionURL = URL(string: "https://admin.mistral.ai/subscription")!

    /// The console's Vibe percentage, used only when the subscription page reports no Vibe
    /// allowance. tRPC batch shape; needs `X-CSRFTOKEN` plus the session cookies.
    static let vibeUsageURL = URL(string: "https://admin.mistral.ai/api/local-trpc/billing.vibeUsage?input=%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%2C%22v%22%3A1%7D%7D")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// The subscription page (both allowances). Best-effort: a failure falls back to the Vibe
    /// tRPC route and, without the API budget, to "No usage data".
    func fetchSubscriptionPage(auth: MistralAuth) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.subscriptionURL,
            headers: [
                "Cookie": auth.cookieHeader,
                "Accept": "text/html",
                "Accept-Language": "en-US,en;q=0.9",
                "Referer": Self.subscriptionURL.absoluteString
            ],
            timeout: 15
        ))
    }

    /// The console Vibe percentage. Best-effort fallback; needs the CSRF token.
    func fetchVibeUsage(auth: MistralAuth) async throws -> HTTPResponse {
        var headers = [
            "Cookie": auth.cookieHeader,
            "Accept": "*/*",
            "Referer": "https://admin.mistral.ai/subscription",
            "x-trpc-source": "nextjs-react"
        ]
        if let csrf = auth.csrfToken {
            headers["X-CSRFTOKEN"] = csrf
        }
        return try await http.send(HTTPRequest(
            method: "GET",
            url: Self.vibeUsageURL,
            headers: headers,
            timeout: 15
        ))
    }
}

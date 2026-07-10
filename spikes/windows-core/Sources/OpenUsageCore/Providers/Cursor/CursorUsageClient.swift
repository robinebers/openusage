import Foundation

struct CursorSession: Equatable, Sendable {
    var userID: String
    var sessionToken: String
}

struct CursorUsageClient: Sendable {
    static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    static let planURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!
    static let refreshURL = URL(string: "https://api2.cursor.sh/oauth/token")!
    static let creditsURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance")!
    static let restUsageURL = URL(string: "https://cursor.com/api/usage")!
    static let stripeURL = URL(string: "https://cursor.com/api/auth/stripe")!
    static let exportCSVURL = URL(string: "https://cursor.com/api/dashboard/export-usage-events-csv")!
    static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func refreshToken(_ refreshToken: String) async throws -> HTTPResponse {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken
        ]
        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.usageURL, accessToken: accessToken)
    }

    func fetchPlan(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.planURL, accessToken: accessToken)
    }

    func fetchCredits(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.creditsURL, accessToken: accessToken)
    }

    func fetchRequestBasedUsage(accessToken: String) async throws -> HTTPResponse? {
        guard let session = Self.session(from: accessToken) else { return nil }
        var components = URLComponents(url: Self.restUsageURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user", value: session.userID)]
        guard let url = components?.url else { return nil }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: ["Cookie": "WorkosCursorSessionToken=\(session.sessionToken)"],
            timeout: 10
        ))
    }

    func fetchStripeBalance(accessToken: String) async throws -> HTTPResponse? {
        guard let session = Self.session(from: accessToken) else { return nil }
        return try await http.send(HTTPRequest(
            method: "GET",
            url: Self.stripeURL,
            headers: ["Cookie": "WorkosCursorSessionToken=\(session.sessionToken)"],
            timeout: 10
        ))
    }

    /// GET the dashboard usage CSV for `[start, end]` (epoch-ms query params, token strategy) using the
    /// same `WorkosCursorSessionToken` cookie as the Stripe/REST calls. Returns nil when the access token
    /// carries no usable session.
    func fetchUsageCSV(accessToken: String, start: Date, end: Date) async throws -> HTTPResponse? {
        guard let session = Self.session(from: accessToken) else { return nil }
        var components = URLComponents(url: Self.exportCSVURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "startDate", value: String(Int(start.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "endDate", value: String(Int(end.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "strategy", value: "tokens")
        ]
        guard let url = components?.url else { return nil }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Cookie": "WorkosCursorSessionToken=\(session.sessionToken)",
                "Accept": "text/csv"
            ],
            timeout: 30
        ))
    }

    private func connectPost(_ url: URL, accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1"
            ],
            body: Data("{}".utf8),
            timeout: 10
        ))
    }

    static func session(from accessToken: String) -> CursorSession? {
        guard let subject = CursorAuthStore.tokenSubject(accessToken) else { return nil }
        let parts = subject.split(separator: "|", omittingEmptySubsequences: false)
        let userID = String(parts.count > 1 ? parts[1] : parts[0])
        guard !userID.isEmpty else { return nil }
        return CursorSession(userID: userID, sessionToken: "\(userID)%3A%3A\(accessToken)")
    }
}

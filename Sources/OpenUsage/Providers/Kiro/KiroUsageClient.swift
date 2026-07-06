import Foundation

struct KiroUsageClient: Sendable {
    /// AWS CodeWhisperer endpoint used by kiro-cli for GetUsageLimits.
    static let codeWhispererEndpoint = "https://codewhisperer.us-east-1.amazonaws.com/"
    static let getUsageLimitsTarget = "AmazonCodeWhispererService.GetUsageLimits"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsageLimits(auth: KiroAuth) async throws -> HTTPResponse {
        guard let url = URL(string: Self.codeWhispererEndpoint) else {
            throw KiroUsageError.connectionFailed
        }

        var body: [String: Any] = [:]
        if let profileArn = auth.profileArn {
            body["profileArn"] = profileArn
        }

        return try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Content-Type": "application/x-amz-json-1.0",
                "x-amz-target": Self.getUsageLimitsTarget,
                "Authorization": "Bearer \(auth.accessToken)"
            ],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))
    }
}

enum KiroUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case usageUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Could not connect to Kiro. Check your internet connection."
        case .invalidResponse, .usageUnavailable:
            return "Kiro usage data unavailable. Try again later."
        }
    }
}

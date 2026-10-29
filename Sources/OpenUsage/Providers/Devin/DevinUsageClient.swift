import Foundation

struct DevinUsageClient: Sendable {
    static let defaultAPIServerURL = URL(string: "https://server.codeium.com")!
    static let apiServerURLKey = "api_server_url"
    static let cloudCompatVersion = "1.108.2"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUserStatus(_ tokens: OAuthTokens) async throws -> HTTPResponse {
        let apiServerURL = tokens.extras[Self.apiServerURLKey].flatMap { URL(string: $0) } ?? Self.defaultAPIServerURL
        let body: [String: Any] = [
            "metadata": [
                "apiKey": tokens.accessToken,
                "ideName": "devin",
                "ideVersion": Self.cloudCompatVersion,
                "extensionName": "devin",
                "extensionVersion": Self.cloudCompatVersion,
                "locale": "en"
            ]
        ]
        return try await http.send(HTTPRequest(
            method: "POST",
            url: apiServerURL.appending(path: "exa.seat_management_pb.SeatManagementService/GetUserStatus"),
            headers: [
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1"
            ],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))
    }
}

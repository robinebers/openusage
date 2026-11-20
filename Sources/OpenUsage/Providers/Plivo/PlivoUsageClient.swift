import Foundation

/// Plivo signs every request with HTTP Basic auth, the Auth ID as the user and the Auth Token as the
/// password. The account keeps both in one key, `AUTH_ID:AUTH_TOKEN`.
struct PlivoCredentials: Equatable, Sendable {
    let authID: String
    let authToken: String

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, !parts[1].isEmpty, parts[0].wholeMatch(of: #/[A-Za-z0-9]+/#) != nil else { return nil }
        authID = parts[0]
        authToken = parts[1]
    }
}

struct PlivoUsageClient: Sendable {
    var http: any HTTPClient

    func fetchAccount(_ credentials: PlivoCredentials) async throws -> HTTPResponse {
        guard let url = URL(string: "https://api.plivo.com/v1/Account/\(credentials.authID)/") else {
            throw ProviderError.invalidResponse
        }
        let basic = Data("\(credentials.authID):\(credentials.authToken)".utf8).base64EncodedString()
        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: ["Authorization": "Basic \(basic)", "Accept": "application/json"]
        ))
    }
}

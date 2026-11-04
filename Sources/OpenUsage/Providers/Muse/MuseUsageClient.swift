import Foundation

/// Reads a Muse Code subscription through the request the Muse CLI makes at startup. Its answer also
/// carries the account's Model API key, so the body is decoded only into `MuseAccount`, which has no
/// field for the key, and goes nowhere else.
struct MuseUsageClient: Sendable {
    static let keyURL = URL(string: "https://api.meta.ai/muse-code/key")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func account(token: String) async throws -> MuseAccount {
        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.keyURL,
            headers: [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "x-api-version": "1.0.0"
            ],
            body: Data(#"{"onboard":false}"#.utf8),
            timeout: 15
        ))
        try ProviderError.requireSuccess(response, kind: .muse)
        guard let account = try? JSONDecoder().decode(MuseAccount.self, from: response.body) else {
            throw ProviderError.invalidResponse
        }
        return account
    }
}

/// The fields OpenUsage reads from Muse Code's key response, and nothing else.
struct MuseAccount: Decodable, Sendable {
    let isSubscribed: Bool
    let plan: String?
    let email: String?
    let usage: Usage?

    struct Usage: Decodable, Sendable {
        let window: Window?
        let weekly: Window?
    }

    struct Window: Decodable, Sendable {
        let usedPercent: Double
        let resetsAt: Date?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try container.decode(Double.self, forKey: .usedPercent)
            resetsAt = try container.decodeIfPresent(Double.self, forKey: .resetsAt).map(Date.init(timeIntervalSince1970:))
        }
    }

    enum CodingKeys: String, CodingKey {
        case isSubscribed = "is_subs_active"
        case plan = "subs_tier_name"
        case email = "user_email"
        case usage = "subs_usage"
    }
}

import CryptoKit
import Foundation

/// Signs a request the way the `ollama` CLI does, so ollama.com accepts it from OpenUsage exactly as it
/// would from Ollama itself.
///
/// The challenge is `"<METHOD>,<request-uri>"` where the request URI carries a `ts` unix-seconds query
/// parameter (the server rejects a stale timestamp, which is what stops a captured header from being
/// replayed later). The header value is `"<base64 public key>:<base64 signature>"` — the same shape
/// `auth.Sign` produces in the Ollama source.
enum OllamaRequestSigner {
    static func authorization(key: OllamaSigningKey, method: String, requestURI: String) throws -> String {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key.seed)
        let signature = try privateKey.signature(for: Data("\(method),\(requestURI)".utf8))
        return "\(key.publicKeyBase64):\(signature.base64EncodedString())"
    }
}

/// Calls ollama.com's account endpoints with a signed request.
///
/// - `GET /api/usage` — the session, weekly, and monthly limit meters plus recent activity spend.
///   This is the endpoint Ollama's own settings page reads; it is undocumented, so the mapper treats
///   every field as optional rather than assuming a shape.
/// - `POST /api/me` — the account's plan name (`free` / `pro` / `max`), used only for the plan badge.
struct OllamaUsageClient: Sendable {
    static let host = "https://ollama.com"
    static let usagePath = "/api/usage"
    static let accountPath = "/api/me"

    var http: any HTTPClient
    /// Injected so the signed timestamp is deterministic in tests.
    var now: @Sendable () -> Date

    init(http: any HTTPClient = URLSessionHTTPClient(), now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http
        self.now = now
    }

    /// Session, weekly, and monthly limits plus recent activity. Required for a usable snapshot.
    func fetchUsage(key: OllamaSigningKey) async throws -> HTTPResponse {
        try await send(method: "GET", path: Self.usagePath, key: key)
    }

    /// The signed-in account — best-effort, used only to surface the plan name.
    func fetchAccount(key: OllamaSigningKey) async throws -> HTTPResponse {
        try await send(method: "POST", path: Self.accountPath, key: key)
    }

    private func send(method: String, path: String, key: OllamaSigningKey) async throws -> HTTPResponse {
        let requestURI = "\(path)?ts=\(Int(now().timeIntervalSince1970))"
        // The signature covers the exact URI that goes on the wire, so build the header from the same
        // string the URL is made of.
        let authorization = try OllamaRequestSigner.authorization(key: key, method: method, requestURI: requestURI)
        guard let url = URL(string: Self.host + requestURI) else {
            throw OllamaUsageError.invalidResponse
        }
        return try await http.send(HTTPRequest(
            method: method,
            url: url,
            headers: [
                "Authorization": authorization,
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum OllamaUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}

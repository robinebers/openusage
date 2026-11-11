import Foundation

enum ProviderError: Error, LocalizedError, Equatable {
    case signInExpired(ProviderKind)
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case unavailable(String)
    case keyRejected(String)
    /// A server between OpenUsage and the provider, such as a CLIProxyAPI hub, can't be reached.
    case unreachable(String)
    /// Like `unreachable`, but the request never left this Mac because it had no network path. See `URLError.meansOffline`.
    case offline(String)

    var errorDescription: String? {
        switch self {
        case .signInExpired(let kind): "\(kind.displayName) sign-in expired. Sign in again to keep reading usage."
        case .connectionFailed: "Connection failed. Check your internet connection and try again."
        case .invalidResponse: "The provider returned an invalid response."
        case .requestFailed(let status): "The provider request failed (HTTP \(status))."
        case .rateLimited: "The provider asked OpenUsage to wait before asking again."
        case .unavailable(let message): message
        case .keyRejected(let message): "\(message) Replace it on the account's page."
        case .unreachable(let message), .offline(let message): message
        }
    }

    static func isAuthFailure(_ response: HTTPResponse) -> Bool {
        response.statusCode == 401 || (response.statusCode == 403 && !isRateLimit(response))
    }

    /// GitHub sends its rate limits as 403 with `x-ratelimit-remaining: 0` or `retry-after`.
    private static func isRateLimit(_ response: HTTPResponse) -> Bool {
        response.statusCode == 429
            || (response.statusCode == 403 && (response.header("x-ratelimit-remaining") == "0" || response.header("retry-after") != nil))
    }

    static func requireSuccess(_ response: HTTPResponse, kind: ProviderKind) throws {
        if isAuthFailure(response) { throw ProviderError.signInExpired(kind) }
        guard (200..<300).contains(response.statusCode) else { throw ProviderError.failed(response) }
    }

    static func requireSuccessJSON(_ response: HTTPResponse, kind: ProviderKind) throws -> [String: Any] {
        try requireSuccess(response, kind: kind)
        guard let body = ProviderParse.jsonObject(response.body) else { throw ProviderError.invalidResponse }
        return body
    }

    static func failed(_ response: HTTPResponse, now: Date = Date()) -> ProviderError {
        isRateLimit(response) ? .rateLimited(retryAfter: response.retryAfter(now: now)) : .requestFailed(response.statusCode)
    }
}

extension URLError {
    /// This Mac had no network path for the request, so it never reached a server. Right after launch,
    /// macOS answers a local-network address this way until it lets OpenUsage onto the local network.
    var meansOffline: Bool { code == .notConnectedToInternet || code == .networkConnectionLost }
}

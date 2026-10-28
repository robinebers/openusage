import Foundation

/// The failures an account refresh surfaces on its dashboard card. Every case maps to one message the
/// card shows; no case carries a credential or a response body.
enum ProviderError: Error, LocalizedError, Equatable {
    /// The saved sign-in no longer works (the provider answered 401/403, refused the token refresh, or
    /// asked for a sign-out), so only adding the account again fixes it.
    case signInExpired(ProviderKind)
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The provider answered 429. `retryAfter` is the wait its Retry-After header named, if it named one.
    case rateLimited(retryAfter: TimeInterval?)
    /// The provider answered, but has nothing to meter for this account; the message says why.
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .signInExpired(let kind): "\(kind.displayName) sign-in expired. Add the account again."
        case .connectionFailed: "Connection failed. Check your internet connection and try again."
        case .invalidResponse: "The provider returned an invalid response."
        case .requestFailed(let status): "The provider request failed (HTTP \(status))."
        case .rateLimited: "The provider asked OpenUsage to wait before asking again."
        case .unavailable(let message): message
        }
    }

    static func isAuthFailure(_ response: HTTPResponse) -> Bool {
        response.statusCode == 401 || response.statusCode == 403
    }

    /// Triages a non-2xx: 401/403 means the sign-in expired, 429 a rate limit, anything else a request
    /// failure that carries its status.
    static func requireSuccess(_ response: HTTPResponse, kind: ProviderKind) throws {
        if isAuthFailure(response) { throw ProviderError.signInExpired(kind) }
        guard (200..<300).contains(response.statusCode) else { throw ProviderError.failed(response) }
    }

    /// The error for a non-2xx answer that isn't a sign-in problem: a 429 is a rate limit carrying the
    /// wait the provider named, anything else a failure with its status.
    static func failed(_ response: HTTPResponse, now: Date = Date()) -> ProviderError {
        response.statusCode == 429 ? .rateLimited(retryAfter: response.retryAfter(now: now)) : .requestFailed(response.statusCode)
    }
}

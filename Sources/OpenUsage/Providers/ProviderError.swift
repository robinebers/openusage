import Foundation

enum ProviderError: Error, LocalizedError, Equatable {
    case signInExpired(ProviderKind)
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case unavailable(String)
    case keyRejected(String)

    var errorDescription: String? {
        switch self {
        case .signInExpired(let kind): "\(kind.displayName) sign-in expired. Remove the account and add it again."
        case .connectionFailed: "Connection failed. Check your internet connection and try again."
        case .invalidResponse: "The provider returned an invalid response."
        case .requestFailed(let status): "The provider request failed (HTTP \(status))."
        case .rateLimited: "The provider asked OpenUsage to wait before asking again."
        case .unavailable(let message): message
        case .keyRejected(let message): "\(message) Replace it on the account's page."
        }
    }

    static func isAuthFailure(_ response: HTTPResponse) -> Bool {
        response.statusCode == 401 || response.statusCode == 403
    }

    static func requireSuccess(_ response: HTTPResponse, kind: ProviderKind) throws {
        if isAuthFailure(response) { throw ProviderError.signInExpired(kind) }
        guard (200..<300).contains(response.statusCode) else { throw ProviderError.failed(response) }
    }

    static func failed(_ response: HTTPResponse, now: Date = Date()) -> ProviderError {
        response.statusCode == 429 ? .rateLimited(retryAfter: response.retryAfter(now: now)) : .requestFailed(response.statusCode)
    }
}

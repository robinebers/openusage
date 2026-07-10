import Foundation

/// Shared user-facing copy for the usage-error cases every provider's `UsageError` otherwise repeats
/// verbatim (transport failure, malformed response, non-2xx status). Providers whose wording
/// intentionally differs — e.g. Grok's "billing" phrasing — keep their own strings.
enum ProviderUsageErrorText {
    /// The request never completed (network/transport failure).
    static let connectionFailed = "Usage request failed. Check your connection."
    /// The response came back but could not be parsed.
    static let invalidResponse = "Usage response invalid. Try again later."
    /// The server returned a non-2xx status.
    static func requestFailed(statusCode: Int) -> String {
        "Usage request failed (HTTP \(statusCode)). Try again later."
    }
}

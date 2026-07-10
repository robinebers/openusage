import Foundation

/// The authenticated-fetch sequence every OAuth-style provider ports from its JS plugin, written
/// once: attempt → on 401/403 refresh the token → retry once → a second 401/403 is a hard auth
/// failure. Anything that isn't an auth failure (success, 429, 5xx) returns untouched for the
/// provider's mapper to interpret, so rate-limit and server-error handling stay per-provider.
///
/// The `refreshAccessToken` closure owns everything provider-specific about refreshing: loading
/// the refresh token (throw the provider's auth error when there isn't one), calling the token
/// endpoint, interpreting its body (`invalid_grant`, `shouldLogout`, …), and persisting rotated
/// credentials. Devin deliberately does not use this — its 401/403 path switches auth *sources*
/// (credentials file → app state) rather than refreshing a token.
@MainActor
enum ProviderAuthRetry {
    /// The statuses that mean "the token is bad" rather than "the request failed".
    nonisolated static func isAuthFailure(_ response: HTTPResponse) -> Bool {
        response.statusCode == 401 || response.statusCode == 403
    }

    /// Triage a response that should carry a usable body: a 401/403 means the token went bad (throw
    /// `authExpired`), any other non-2xx is a request failure (throw `requestFailed(status)`), and a
    /// 2xx returns without throwing. Centralizes the guard the Claude/Codex/Grok mappers and
    /// `CursorProvider` each re-spelled inline, routing the auth-status check through `isAuthFailure`.
    nonisolated static func requireSuccess(
        _ response: HTTPResponse,
        authExpired: Error,
        requestFailed: (Int) -> Error
    ) throws {
        guard !isAuthFailure(response) else { throw authExpired }
        guard (200..<300).contains(response.statusCode) else { throw requestFailed(response.statusCode) }
    }

    /// - Parameters:
    ///   - token: access token for the first attempt.
    ///   - attempt: performs the request with the given token; called at most twice.
    ///   - refreshAccessToken: returns a fresh access token or throws the provider's auth error.
    ///   - connectionFailed: thrown when `attempt` itself fails (transport, not status).
    ///   - retriedConnectionFailed: optional distinct error for a transport failure on the retry
    ///     (Cursor reports these separately); defaults to `connectionFailed`.
    ///   - authExpired: thrown when the retried request still comes back 401/403.
    static func fetch(
        token: String,
        attempt: (_ accessToken: String) async throws -> HTTPResponse,
        refreshAccessToken: () async throws -> String,
        connectionFailed: Error,
        retriedConnectionFailed: Error? = nil,
        authExpired: Error
    ) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await attempt(token)
        } catch {
            throw connectionFailed
        }
        guard isAuthFailure(response) else { return response }

        AppLog.debug(.auth, "\(response.statusCode) -> refreshing token, retrying once")
        let refreshed = try await refreshAccessToken()

        let retried: HTTPResponse
        do {
            retried = try await attempt(refreshed)
        } catch {
            throw retriedConnectionFailed ?? connectionFailed
        }
        if isAuthFailure(retried) {
            AppLog.warn(.auth, "retry still unauthorized -> auth expired")
            throw authExpired
        }
        return retried
    }
}

import Foundation

/// Borrows the Capy desktop app's signed-in session, read-only, the way the app itself uses it.
///
/// Capy stores a Clerk *client* JWT in `~/Library/Application Support/Capy/session-credential.json`,
/// encrypted with Electron `safeStorage` (the `Capy Safe Storage` Keychain item). Each API call needs a
/// short-lived (60s) *session* JWT minted from it at Capy's Clerk frontend API. The mint must carry
/// `Origin: capy://app`: Clerk stamps it into the token's `azp` claim, and api.capy.ai rejects any other.
///
/// The client JWT is never written back. Clerk may rotate it in a response header; the desktop app
/// persists its own rotations, and OpenUsage re-reads the file on every scan instead of keeping a copy.
struct CapySession: Sendable {
    var userID: String
    var sessionID: String
    var clientJWT: String

    static let sessionRelativePath = "Library/Application Support/Capy/session-credential.json"
    static let clerkOrigin = "https://clerk.capy.ai"
    /// The desktop app's renderer origin — the only `azp` api.capy.ai accepts for desktop sessions.
    static let appOrigin = "capy://app"
    /// Clerk frontend API versions pinned by Capy desktop 0.2.x.
    static let clerkQuery = "_is_native=1&__clerk_api_version=2025-11-10&_clerk_js_version=5.127.1"

    enum Failure: Error, Equatable {
        /// No session file: Capy isn't installed or is signed out. Not an error worth logging.
        case notSignedIn
        /// The Keychain item exists but this refresh may not prompt for it (background refresh).
        case keychainPermissionRequired
        case unreadable(String)
        case mintRefused(Int)
    }

    static func sessionFileExists(homeDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: homeDirectory.appendingPathComponent(sessionRelativePath).path)
    }

    /// Decrypts the stored session with a key derived from the Keychain password.
    static func load(homeDirectory: URL, key: Data) throws -> CapySession {
        let url = homeDirectory.appendingPathComponent(sessionRelativePath)
        guard let data = FileManager.default.contents(atPath: url.path) else { throw Failure.notSignedIn }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let userID = object["userId"] as? String,
              let sessionID = object["sessionId"] as? String,
              let ciphertext = (object["ciphertext"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { throw Failure.unreadable("session file has an unexpected shape") }
        let plaintext = try ClaudeDesktopAuthStore.decrypt(ciphertext, key: key)
        guard let clientJWT = String(data: plaintext, encoding: .utf8), clientJWT.split(separator: ".").count == 3
        else { throw Failure.unreadable("decrypted session is not a JWT") }
        return CapySession(userID: userID, sessionID: sessionID, clientJWT: clientJWT)
    }

    /// Mints a 60-second session JWT for api.capy.ai.
    func mintToken(http: any HTTPClient) async throws -> String {
        let path = "/v1/client/sessions/\(sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID)/tokens"
        guard let url = URL(string: "\(Self.clerkOrigin)\(path)?\(Self.clerkQuery)") else {
            throw Failure.unreadable("invalid Clerk URL")
        }
        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Authorization": "Bearer \(clientJWT)",
                "Origin": Self.appOrigin,
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json"
            ],
            body: Data()
        ))
        guard response.statusCode == 200 else { throw Failure.mintRefused(response.statusCode) }
        // Clerk answers `{ "jwt": … }`, or the same wrapped in `response` on some API versions.
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let jwt = object?["jwt"] as? String ?? (object?["response"] as? [String: Any])?["jwt"] as? String
        guard let jwt, !jwt.isEmpty else { throw Failure.unreadable("Clerk token response has no jwt") }
        return jwt
    }
}

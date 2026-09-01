import Foundation

/// Reads the OpenCode Go credential already on the machine. Local-only — never the network. The
/// `opencode-go` key is both the first-run detection signal and the Bearer token for
/// `GET /zen/go/v1/usage`, so it lives behind one loader.
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var dataDirectory: String {
        OpenCodePaths.dataDirectory(environment: environment, homeDirectory: homeDirectory())
    }

    var authFilePath: String {
        OpenCodePaths.authFilePath(dataDirectory: dataDirectory)
    }

    /// The non-empty `opencode-go` API key from `auth.json`, or `nil` when the user has not logged into
    /// OpenCode Go. Reads only that one entry — tolerant of unrelated sibling entries (other providers, or
    /// a future non-object field like a schema marker) so one odd value can't hide a valid key. A present
    /// file that can't be read or parsed throws `credentialsUnreadable` so broken storage is never
    /// mistaken for logout; an absent file is the normal "not logged in" `nil`.
    func goAPIKey() throws -> String? {
        guard let object = try authObject() else { return nil }
        guard let entry = object["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String
        else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Whether OpenCode's `openai` provider is currently authenticated through the built-in ChatGPT /
    /// Codex OAuth flow. OpenCode stores API-key and OAuth credentials under the same provider key, so
    /// checking the auth type is required before attributing its `providerID = openai` database rows to
    /// the Codex card. Secrets stay inside the auth boundary and are never returned or logged.
    func hasCodexOAuth() throws -> Bool {
        guard let object = try authObject(),
              let entry = object["openai"] as? [String: Any],
              entry["type"] as? String == "oauth"
        else { return false }
        return ["access", "refresh"].contains { field in
            ((entry[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty) != nil
        }
    }

    private func authObject() throws -> [String: Any]? {
        let text: String?
        do {
            text = try files.readTextIfPresent(authFilePath)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
        guard let text else { return nil }
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "auth.json is not valid JSON")
        }
        return object
    }
}

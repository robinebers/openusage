import Foundation

/// Reads the OpenCode Go credential already on the machine. Local-only — never the network. The
/// `opencode-go` key is both the first-run detection signal and the Bearer token for
/// `GET /zen/go/v1/usage`, so it lives behind one loader.
///
/// Codex attribution also needs to know whether OpenCode's `openai` provider is ChatGPT OAuth.
/// OpenCode 2 moved that credential from `auth.json` into the SQLite `credential` table; the live
/// database wins because OpenCode 2 imports the file without deleting it, so a retained file entry
/// goes stale after a later login.
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]

    /// OpenCode 2 `credential` lookups, current row first: superseded rows stay in the table, so an
    /// unordered `LIMIT 1` can return a previous account. Ordering mirrors OpenCode (`active DESC,
    /// time_updated DESC, id DESC`); the filter admits NULL-flagged imports.
    static let credentialSQLCurrentOpenAI =
        "SELECT value FROM credential WHERE integration_id = 'openai' AND (active IS NULL OR active = 1) ORDER BY active DESC, time_updated DESC, id DESC LIMIT 1;"
    static let credentialSQLCurrentOpenAITime =
        "SELECT time_created FROM credential WHERE integration_id = 'openai' AND (active IS NULL OR active = 1) ORDER BY active DESC, time_updated DESC, id DESC LIMIT 1;"

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: (@Sendable () throws -> [String])? = nil
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.sqlite = sqlite
        if let databasePaths {
            self.databasePaths = databasePaths
        } else {
            let env = environment
            let home = homeDirectory
            self.databasePaths = {
                let dir = OpenCodePaths.dataDirectory(environment: env, homeDirectory: home())
                return try OpenCodePaths.databaseFiles(in: dir)
            }
        }
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

    /// The current `openai` credential: whether it is ChatGPT/Codex OAuth, and when its row was
    /// created (`nil` for file-based credentials, which carry no timestamp).
    struct OpenAICredential: Sendable {
        var isOAuth: Bool
        var since: Date?
    }

    /// The current `openai` credential, database first so a retained `auth.json` cannot hide a later
    /// login. The row is chosen before its type is checked — OAuth-first filtering would resurrect an
    /// inactive account while the live credential is an API key.
    func openAICredential() throws -> OpenAICredential {
        if let value = credentialValue(from: Self.credentialSQLCurrentOpenAI),
           let data = value.data(using: .utf8),
           let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var since: Date?
            if let ms = credentialValue(from: Self.credentialSQLCurrentOpenAITime).flatMap(Double.init) {
                since = Date(timeIntervalSince1970: ms / 1000)
            }
            return OpenAICredential(isOAuth: Self.isCodexOAuth(entry), since: since)
        }
        if let entry = try authObject()?["openai"] as? [String: Any] {
            return OpenAICredential(isOAuth: Self.isCodexOAuth(entry), since: nil)
        }
        return OpenAICredential(isOAuth: false, since: nil)
    }

    /// Whether OpenCode's `openai` provider is currently authenticated through the built-in ChatGPT /
    /// Codex OAuth flow. OpenCode stores API-key and OAuth credentials under the same provider key, so
    /// checking the auth type is required before attributing its `providerID = openai` database rows to
    /// the Codex card. Secrets stay inside the auth boundary and are never returned or logged.
    func hasCodexOAuth() throws -> Bool {
        try openAICredential().isOAuth
    }

    /// One OAuth entry is enough — OpenCode writes both fields, but a refresh-only or access-only row
    /// still proves the OAuth flow rather than an API key.
    private static func isCodexOAuth(_ entry: [String: Any]) -> Bool {
        guard entry["type"] as? String == "oauth" else { return false }
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

    /// Best-effort lookup across all `opencode*.db` files. Missing tables read as "not stored there";
    /// anything else that fails is logged, since the Codex scanner exits at its auth guard and would
    /// otherwise drop usage silently. Never throws — a missing OAuth credential is simply "not OAuth".
    private func credentialValue(from sql: String) -> String? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(
                LogTag.plugin("opencode"),
                "credential lookup skipped: data directory unreadable: \(error.localizedDescription)"
            )
            return nil
        }
        for path in paths {
            do {
                if let value = try sqlite.queryValue(path: path, sql: sql)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    return value
                }
            } catch {
                // Pre-OpenCode-2 databases have no `credential` table — expected, not an error.
                if Self.isMissingCredentialTable(error) { continue }
                AppLog.warn(
                    LogTag.plugin("opencode"),
                    "credential lookup failed for \(path): \(error.localizedDescription)"
                )
                continue
            }
        }
        return nil
    }

    private static func isMissingCredentialTable(_ error: Error) -> Bool {
        let detail: String
        if let sqlite = error as? SQLiteError, case .queryFailed(let message) = sqlite {
            detail = message
        } else {
            detail = error.localizedDescription
        }
        return detail.localizedCaseInsensitiveContains("no such table")
    }
}

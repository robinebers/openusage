import Foundation

/// Reads the OpenCode Go credential already on the machine. Local-only — never the network. The
/// `opencode-go` key is both the first-run detection signal and the Bearer token for
/// `GET /zen/go/v1/usage`, so it lives behind one loader.
///
/// Codex attribution also needs to know whether OpenCode's `openai` provider is ChatGPT OAuth.
/// OpenCode 2 moved that credential from `auth.json` into each channel database's `credential`
/// table: it imports the file once per database and never deletes it, so once a database has that
/// table the file is stale for it — a later login or logout only shows up in the table.
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    var sqlite: SQLiteAccessing

    /// The current `openai` row of one database. Ordering mirrors OpenCode (`active DESC,
    /// time_updated DESC, id DESC`); the filter admits NULL-flagged imports. `json(value)` embeds
    /// the credential object so Swift does not re-parse a nested string.
    static let credentialSQLCurrentOpenAI = """
        SELECT json_array(json(value), time_created)
        FROM credential
        WHERE integration_id = 'openai' AND (active IS NULL OR active = 1)
        ORDER BY active DESC, time_updated DESC, id DESC
        LIMIT 1;
        """

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        sqlite: SQLiteAccessing = SQLiteCLIAccessor()
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.sqlite = sqlite
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

    /// The `openai` credential that governs one channel database. OpenCode partitions credentials
    /// by release channel, so `opencode.db` and `opencode-next.db` can hold different logins and
    /// each database's usage must be judged by its own. The row is chosen before its type is
    /// checked — OAuth-first filtering would resurrect an inactive account while the live credential
    /// is an API key. `auth.json` stands in only for an OpenCode 1 database (no `credential` table).
    /// Throws when the database or `auth.json` can't be read; the caller must not read that as "no
    /// credential", or a locked file would revive the stale import.
    func openAICredential(databasePath: String) throws -> OpenAICredential {
        do {
            if let json = try sqlite.queryValue(path: databasePath, sql: Self.credentialSQLCurrentOpenAI)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                guard let row = Self.parseOpenAICredentialRow(json) else {
                    throw OpenCodeUsageError.credentialsUnreadable(detail: "credential row is malformed")
                }
                return OpenAICredential(isOAuth: Self.isCodexOAuth(row.entry), since: row.since)
            }
            // The table exists but holds no `openai` row: the user logged out of OpenCode 2, which
            // deletes the row and leaves the imported `auth.json` behind. That file must not revive it.
            return OpenAICredential(isOAuth: false, since: nil)
        } catch {
            // Pre-OpenCode-2 databases have no `credential` table — `auth.json` is still live there.
            // `SQLiteError.errorDescription` is sqlite3's stderr, so this is the raw message.
            guard error.localizedDescription.localizedCaseInsensitiveContains("no such table") else { throw error }
        }
        if let entry = try authObject()?["openai"] as? [String: Any] {
            return OpenAICredential(isOAuth: Self.isCodexOAuth(entry), since: nil)
        }
        return OpenAICredential(isOAuth: false, since: nil)
    }

    /// Whether an `openai` entry is the built-in ChatGPT / Codex OAuth flow. OpenCode stores API-key
    /// and OAuth credentials under the same provider key, so the type must be checked before
    /// attributing `providerID = openai` rows to the Codex card. Secrets stay inside the auth boundary
    /// and are never returned or logged. One OAuth field is enough — OpenCode writes both, but a
    /// refresh-only or access-only row still proves the OAuth flow rather than an API key.
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

    private struct OpenAICredentialRow {
        var entry: [String: Any]
        var since: Date?
    }

    /// Epoch milliseconds through the year 33658: anything past this is not a timestamp, and it keeps
    /// the later `Int(seconds * 1000)` conversion far from the trap at `Int.max`.
    private static let maxTimestampMs: Double = 1e15

    /// `[value, time_created]` from `credentialSQLCurrentOpenAI`. `nil` when the row is malformed,
    /// including a `time_created` that is not a plausible timestamp.
    private static func parseOpenAICredentialRow(_ json: String) -> OpenAICredentialRow? {
        guard let data = json.data(using: .utf8),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              values.count >= 2
        else { return nil }
        let entry: [String: Any]
        if let object = values[0] as? [String: Any] {
            entry = object
        } else if let text = values[0] as? String,
                  let nested = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: nested)) as? [String: Any] {
            entry = object
        } else {
            return nil
        }
        var since: Date?
        if !(values[1] is NSNull) {
            guard let ms = ProviderParse.number(values[1]), ms.isFinite, (0...maxTimestampMs).contains(ms) else {
                return nil
            }
            since = Date(timeIntervalSince1970: ms / 1000)
        }
        return OpenAICredentialRow(entry: entry, since: since)
    }
}

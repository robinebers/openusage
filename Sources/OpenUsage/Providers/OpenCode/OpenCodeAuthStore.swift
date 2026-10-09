import Foundation

/// Reads the OpenCode Go credential already on the machine. Local-only — never the network. The
/// `opencode-go` key is both the first-run detection signal and the Bearer token for
/// `GET /zen/go/v1/usage`, so it lives behind one loader. OpenCode 2 stores it in the channel
/// databases' `credential` table; OpenCode 1 in `auth.json`.
///
/// Codex attribution also needs to know whether OpenCode's `openai` provider is ChatGPT OAuth.
/// OpenCode 2 moved that credential from `auth.json` into each channel database's `credential`
/// table: it imports the file once per database and never deletes it, so after the import migration
/// runs, later logins and logouts only show up in the table.
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    var sqlite: SQLiteAccessing
    /// Every channel database to read `credential` rows from; `nil` globs the data directory.
    var databasePaths: (@Sendable () throws -> [String])?

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

    /// The current `opencode-go` API key of one database, in the same order as the `openai` row.
    static let credentialSQLGoKey = """
        SELECT json_extract(value,'$.key')
        FROM credential
        WHERE integration_id = 'opencode-go' AND (active IS NULL OR active = 1)
        ORDER BY active DESC, time_updated DESC, id DESC
        LIMIT 1;
        """

    static let credentialsImportedSQL = "SELECT 1 FROM migration WHERE id = '20260805200742_import_legacy_credentials' LIMIT 1;"

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
        self.databasePaths = databasePaths
    }

    var dataDirectory: String {
        OpenCodePaths.dataDirectory(environment: environment, homeDirectory: homeDirectory())
    }

    var authFilePath: String {
        OpenCodePaths.authFilePath(dataDirectory: dataDirectory)
    }

    /// The non-empty `opencode-go` API key, or `nil` when the user has not logged into OpenCode Go.
    /// OpenCode 2 keeps it in each channel database's `credential` table; the first database holding
    /// a key wins. `auth.json` stays live until OpenCode 2 imports it into a database; after that, a
    /// logout must not be revived by the file. Reads only the `opencode-go` entry, tolerant of
    /// unrelated sibling entries. A present file or database that can't be read throws
    /// `credentialsUnreadable` so broken storage is never mistaken for logout.
    func goAPIKey() throws -> String? {
        let paths: [String]
        do {
            paths = try databasePaths?() ?? OpenCodePaths.databaseFiles(in: dataDirectory)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
        var hasCredentialTable = false
        var failure: Error?
        for path in paths {
            do {
                guard try credentialsImported(path: path) else { continue }
                let value = try sqlite.queryValue(path: path, sql: Self.credentialSQLGoKey)
                hasCredentialTable = true
                if let key = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    return key
                }
            } catch where Self.isMissingTable(error) {
                continue
            } catch {
                failure = error
            }
        }
        if let failure {
            throw OpenCodeUsageError.credentialsUnreadable(detail: failure.localizedDescription)
        }
        if hasCredentialTable { return nil }
        guard let object = try authObject(),
              let entry = object["opencode-go"] as? [String: Any],
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
    /// is an API key. `auth.json` stays live until OpenCode 2 imports it into this database.
    /// Throws when the database or `auth.json` can't be read; the caller must not read that as "no
    /// credential", or a locked file would revive the stale import.
    func openAICredential(databasePath: String) throws -> OpenAICredential {
        do {
            if try credentialsImported(path: databasePath) {
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
            }
        } catch {
            // A missing credential table leaves `auth.json` as the available source.
            guard Self.isMissingTable(error) else { throw error }
        }
        if let entry = try authObject()?["openai"] as? [String: Any] {
            return OpenAICredential(isOAuth: Self.isCodexOAuth(entry), since: nil)
        }
        return OpenAICredential(isOAuth: false, since: nil)
    }

    private func credentialsImported(path: String) throws -> Bool {
        do {
            return try sqlite.queryValue(path: path, sql: Self.credentialsImportedSQL) != nil
        } catch where Self.isMissingTable(error) {
            return false
        }
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

    /// `SQLiteError.errorDescription` is sqlite3's stderr, so this matches its raw message.
    private static func isMissingTable(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("no such table")
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

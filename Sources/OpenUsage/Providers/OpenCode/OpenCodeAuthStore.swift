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
    /// Test seam; `nil` globs `opencode*.db` under `dataDirectory`.
    var databasePaths: (@Sendable () throws -> [String])?

    /// One current `openai` row per database: ranking fields ride with the value so the live row can
    /// be chosen across channel files (`opencode-next.db` sorts before `opencode.db`). Ordering
    /// mirrors OpenCode (`active DESC, time_updated DESC, id DESC`); the filter admits NULL-flagged
    /// imports. `json(value)` embeds the credential object so Swift does not re-parse a nested string.
    static let credentialSQLCurrentOpenAI = """
        SELECT json_array(json(value), active, time_updated, id, time_created)
        FROM credential
        WHERE integration_id = 'openai' AND (active IS NULL OR active = 1)
        ORDER BY active DESC, time_updated DESC, id DESC
        LIMIT 1;
        """

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
    /// inactive account while the live credential is an API key. Ranking is global across channel
    /// databases: the first file that returns a row is not automatically the live account.
    func openAICredential() throws -> OpenAICredential {
        let lookup = currentOpenAICredentialFromDatabases()
        if let row = lookup.row {
            return OpenAICredential(isOAuth: Self.isCodexOAuth(row.entry), since: row.since)
        }
        // A locked or unreadable database is not "no credential" — falling through would revive the
        // imported auth.json that OpenCode 2 no longer updates.
        if lookup.hadHardFailure {
            return OpenAICredential(isOAuth: false, since: nil)
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
        /// Kept as `Double`: `Int(Double)` traps above `Int64.max`, and these only need ordering.
        var active: Double?
        var timeUpdated: Double
        var id: String
        var since: Date?
    }

    /// Current `openai` row across every `opencode*.db`. Missing `credential` tables skip; any other
    /// SQLite failure is a hard failure so `auth.json` cannot stand in.
    private func currentOpenAICredentialFromDatabases() -> (row: OpenAICredentialRow?, hadHardFailure: Bool) {
        let paths: [String]
        do {
            paths = try databasePaths?() ?? OpenCodePaths.databaseFiles(in: dataDirectory)
        } catch {
            AppLog.warn(
                LogTag.plugin("opencode"),
                "credential lookup skipped: data directory unreadable: \(error.localizedDescription)"
            )
            return (nil, true)
        }
        var rows: [OpenAICredentialRow] = []
        var hadHardFailure = false
        for path in paths {
            do {
                guard let json = try sqlite.queryValue(path: path, sql: Self.credentialSQLCurrentOpenAI)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                      let row = Self.parseOpenAICredentialRow(json)
                else { continue }
                rows.append(row)
            } catch {
                // Pre-OpenCode-2 databases have no `credential` table — expected, not an error.
                // `SQLiteError.errorDescription` is sqlite3's stderr, so this is the raw message.
                if error.localizedDescription.localizedCaseInsensitiveContains("no such table") { continue }
                hadHardFailure = true
                AppLog.warn(
                    LogTag.plugin("opencode"),
                    "credential lookup failed for \(path): \(error.localizedDescription)"
                )
            }
        }
        return (rows.max(by: { Self.isPreferred($1, over: $0) }), hadHardFailure)
    }

    /// `[value, active, time_updated, id, time_created]` from `credentialSQLCurrentOpenAI`.
    private static func parseOpenAICredentialRow(_ json: String) -> OpenAICredentialRow? {
        guard let data = json.data(using: .utf8),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              values.count >= 5
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
        let active = values[1] is NSNull ? nil : ProviderParse.number(values[1])
        let timeUpdated = ProviderParse.number(values[2]) ?? 0
        let id = (values[3] as? String) ?? ""
        var since: Date?
        if !(values[4] is NSNull), let ms = ProviderParse.number(values[4]) {
            since = Date(timeIntervalSince1970: ms / 1000)
        }
        return OpenAICredentialRow(entry: entry, active: active, timeUpdated: timeUpdated, id: id, since: since)
    }

    /// Same order as the SQL `ORDER BY`: active DESC (NULL last), time_updated DESC, id DESC.
    private static func isPreferred(_ lhs: OpenAICredentialRow, over rhs: OpenAICredentialRow) -> Bool {
        let leftActive = lhs.active ?? -.infinity
        let rightActive = rhs.active ?? -.infinity
        if leftActive != rightActive { return leftActive > rightActive }
        if lhs.timeUpdated != rhs.timeUpdated { return lhs.timeUpdated > rhs.timeUpdated }
        return lhs.id > rhs.id
    }
}

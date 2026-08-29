import Foundation

/// Reads the OpenCode Go credential already on the machine. Local-only — never the network. The
/// `opencode-go` key is both the first-run detection signal and the Bearer token for
/// `GET /zen/go/v1/usage`, so it lives behind one loader.
///
/// OpenCode 2 moved auth from `auth.json` (`{"opencode-go":{"key":"sk-..."}}`) to the SQLite
/// `credential` table (`integration_id='opencode-go'`, `value` JSON `{"type":"key","key":"sk-..."}`).
/// This store tries the file first for backwards compat, then falls back to the SQLite credential
/// table across all `opencode*.db` files so fresh installs after 2026 still get Go meters.
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]

    /// Credential lookup in the SQLite `credential` table — tries the Go integration first, then
    /// any `sk-` key as a last resort (mirrors the `opencode-go` → `opencode` fallback in the issue workaround).
    private static let credentialSQLGo = "SELECT json_extract(value,'$.key') FROM credential WHERE integration_id = 'opencode-go' AND json_extract(value,'$.key') LIKE 'sk-%' LIMIT 1;"
    private static let credentialSQLFallback = "SELECT json_extract(value,'$.key') FROM credential WHERE json_extract(value,'$.key') LIKE 'sk-%' LIMIT 1;"

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

    /// The non-empty `opencode-go` API key, or `nil` when the user has not logged into OpenCode Go.
    /// Reads `auth.json` first (OpenCode 1), then falls back to the SQLite `credential` table
    /// (OpenCode 2: `integration_id='opencode-go'` with `value` JSON `{"type":"key","key":"sk-..."}`).
    /// Tolerant of unrelated sibling entries so one odd value can't hide a valid key. A present file
    /// that can't be read or parsed throws `credentialsUnreadable` so broken storage is never mistaken
    /// for logout; an absent file or missing entry falls through to the DB fallback, and only if neither
    /// source has a key does it return `nil`.
    func goAPIKey() throws -> String? {
        let text: String?
        do {
            text = try files.readTextIfPresent(authFilePath)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
        if let text {
            guard let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                throw OpenCodeUsageError.credentialsUnreadable(detail: "auth.json is not valid JSON")
            }
            if let entry = object["opencode-go"] as? [String: Any],
               let key = entry["key"] as? String,
               let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return trimmed
            }
            // File present but no valid opencode-go key — fall through to DB before returning nil
        }
        // File missing or without a valid key — try SQLite credential table (OpenCode 2)
        if let dbKey = credentialKeyFromDatabase() {
            return dbKey
        }
        return nil
    }

    /// Best-effort lookup in `credential` table across all `opencode*.db` files. Tries the
    /// `opencode-go` integration first, then any `sk-` key. Missing tables / databases are ignored;
    /// only a file-level read error throws, so broken DB access is treated as "not logged in" rather
    /// than a user-visible error (the scanner already surfaces DB unreadability).
    private func credentialKeyFromDatabase() -> String? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            return nil
        }
        guard !paths.isEmpty else { return nil }
        // Priority: opencode-go specific key, then any sk- key (covers `opencode` integration or generic)
        for sql in [Self.credentialSQLGo, Self.credentialSQLFallback] {
            for path in paths {
                do {
                    if let value = try sqlite.queryValue(path: path, sql: sql) {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let valid = trimmed.nilIfEmpty {
                            return valid
                        }
                    }
                } catch {
                    continue
                }
            }
        }
        return nil
    }
}

import Foundation

/// Which assistant-message tables a given OpenCode database actually holds. OpenCode 2 creates both
/// tables when it builds a database from its current schema and never drops the legacy one, so most
/// installs have `OpenCodeMessageTables.all` — but a database written by an early 1.18.x build can
/// hold only `session_message`. Naming a missing table fails statement preparation, which the scanner
/// would otherwise report as an unreadable database, so it has to ask before it queries.
struct OpenCodeMessageTables: OptionSet, Sendable {
    let rawValue: Int

    /// The legacy `message` table (OpenCode 1).
    static let v1 = OpenCodeMessageTables(rawValue: 1)
    /// The `session_message` table (OpenCode 2).
    static let v2 = OpenCodeMessageTables(rawValue: 2)
    static let all: OpenCodeMessageTables = [.v1, .v2]
}

/// Where OpenCode keeps its local data on this machine, shared by the auth store (reads `auth.json`)
/// and the usage scanner (reads the SQLite logs). Resolution mirrors OpenCode itself: an explicit
/// `OPENCODE_DATA_DIR` wins, then `$XDG_DATA_HOME/opencode`, then the default `~/.local/share/opencode`.
enum OpenCodePaths {
    static func dataDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let override = environment.value(for: "OPENCODE_DATA_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(override).trimmingTrailingSlashes
        }
        if let xdg = environment.value(for: "XDG_DATA_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(xdg).trimmingTrailingSlashes + "/opencode"
        }
        return homeDirectory.appendingPathComponent(".local/share/opencode").path
    }

    static func authFilePath(dataDirectory: String) -> String {
        dataDirectory.trimmingTrailingSlashes + "/auth.json"
    }

    /// Asks one database which assistant-message tables it holds. Statement preparation fails when a
    /// named table is absent, so the scanners must know before they build a query — see
    /// `OpenCodeMessageTables`.
    static let messageTablesSQL = """
        SELECT (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='message'),
               (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_message');
        """

    /// Reads that probe's `v1|v2` counts. Anything unparseable reads as "no tables", which makes the
    /// caller skip the file rather than query it blind.
    static func messageTables(fromProbeOutput output: String) -> OpenCodeMessageTables {
        let counts = output
            .split(whereSeparator: { $0 == "|" || $0.isWhitespace })
            .compactMap { Int($0) }
        guard counts.count >= 2 else { return [] }
        var tables: OpenCodeMessageTables = []
        if counts[0] > 0 { tables.insert(.v1) }
        if counts[1] > 0 { tables.insert(.v2) }
        return tables
    }

    /// Every `opencode*.db` file in the data dir. OpenCode partitions its database by release channel —
    /// `opencode.db` for stable (latest/beta/prod) and `opencode-<channel>.db` for others (e.g.
    /// `opencode-next.db` for the `next`/preview line). Globbing all of them (rather than hardcoding
    /// `opencode.db`) means a user on the `next` channel is still tracked. The `.db` suffix excludes the
    /// `-wal`/`-shm` sidecars. Path-sorted for deterministic iteration.
    ///
    /// A missing directory is the normal "never used OpenCode" case and returns `[]`; a directory that
    /// exists but can't be enumerated (permissions, I/O) rethrows so the caller can't mistake broken
    /// access for absence.
    static func databaseFiles(in dataDirectory: String) throws -> [String] {
        let dir = expandHome(dataDirectory)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir)
        } catch {
            guard FileManager.default.fileExists(atPath: dir) else { return [] }
            throw error
        }
        return names
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .sorted()
            .map { dir.trimmingTrailingSlashes + "/" + $0 }
    }
}

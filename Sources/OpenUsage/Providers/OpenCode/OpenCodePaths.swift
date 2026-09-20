import Foundation

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

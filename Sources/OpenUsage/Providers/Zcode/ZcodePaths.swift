import Foundation

/// Where Zcode keeps its local data on this machine, shared by first-run detection and the usage
/// scanner (which reads the SQLite accounting database). Resolution mirrors the other local log
/// providers: an explicit `ZCODE_HOME` wins, then the default `~/.zcode`.
enum ZcodePaths {
    /// Zcode has no documented home override, so `ZCODE_HOME` is honoured defensively — it costs one
    /// lookup and keeps a relocated home readable without a release.
    static let homeEnvironmentKey = "ZCODE_HOME"
    static let defaultLeaf = ".zcode"
    /// The accounting database lives one level deeper than the CLI's other state.
    static let databaseLeaf = "cli/db"

    static func homeDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let override = environment.value(for: homeEnvironmentKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(override).trimmingTrailingSlashes
        }
        return homeDirectory.appendingPathComponent(defaultLeaf).path
    }

    static func databaseDirectory(home: String) -> String {
        home.trimmingTrailingSlashes + "/" + databaseLeaf
    }

    /// Every `*.sqlite` file in `<home>/cli/db`. Zcode ships a single `db.sqlite` today; globbing lets a
    /// future sharded or per-environment store be picked up without a release, and the `.sqlite`
    /// suffix excludes the `-wal`/`-shm` sidecars. Path-sorted for deterministic iteration.
    ///
    /// A missing directory is the normal "never used Zcode" case and returns `[]`; a directory that
    /// exists but can't be enumerated (permissions, I/O) rethrows so the caller can't mistake broken
    /// access for absence.
    static func databaseFiles(in home: String) throws -> [String] {
        let dir = expandHome(databaseDirectory(home: home))
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir)
        } catch {
            guard FileManager.default.fileExists(atPath: dir) else { return [] }
            throw error
        }
        return names
            .filter { $0.hasSuffix(".sqlite") }
            .sorted()
            .map { dir.trimmingTrailingSlashes + "/" + $0 }
            .filter { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
    }
}

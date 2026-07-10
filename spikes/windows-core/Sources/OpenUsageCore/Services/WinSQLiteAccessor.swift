import Foundation
#if os(Windows)
import Win32Shim
#endif

enum SQLiteError: Error, LocalizedError, Equatable {
    case queryFailed(String)
    case readOnly

    var errorDescription: String? {
        switch self {
        case .queryFailed(let message):
            return message.isEmpty ? "SQLite query failed." : message
        case .readOnly:
            return "SQLite writes to third-party stores are disabled."
        }
    }
}

protocol SQLiteAccessing: Sendable {
    func queryValue(path: String, sql: String) throws -> String?
    func execute(path: String, sql: String) throws
}

#if os(Windows)

/// Read-only SQLite access via `winsqlite3.dll`. Copies the DB (+ WAL/SHM sidecars) to a temp
/// directory when the live file is busy/locked by a running app (e.g. Cursor).
struct WinSQLiteAccessor: SQLiteAccessing {
    func queryValue(path: String, sql: String) throws -> String? {
        let expanded = WellKnownPaths.expandHome(path)
        return try queryValue(expandedPath: expanded, sql: sql, allowCopyFallback: true)
    }

    func execute(path: String, sql: String) throws {
        throw SQLiteError.readOnly
    }

    private func queryValue(expandedPath: String, sql: String, allowCopyFallback: Bool) throws -> String? {
        do {
            return try queryValueOnce(expandedPath: expandedPath, sql: sql)
        } catch SQLiteError.queryFailed(let message) where allowCopyFallback && Self.isBusyOrLocked(message) {
            let copied = try copyDatabaseBundle(from: expandedPath)
            return try queryValue(expandedPath: copied, sql: sql, allowCopyFallback: false)
        }
    }

    private func queryValueOnce(expandedPath: String, sql: String) throws -> String? {
        var db: OpaquePointer?
        let openRC = ou_sqlite_open_readonly(expandedPath, &db)
        guard openRC == OU_SQLITE_OK, let db else {
            throw SQLiteError.queryFailed(Self.errorLabel(openRC))
        }
        defer { _ = ou_sqlite_close(db) }

        var out: UnsafeMutablePointer<CChar>?
        let queryRC = ou_sqlite_query_scalar_text(db, sql, &out)
        defer {
            if let out { ou_sqlite_free_string(out) }
        }
        guard queryRC == OU_SQLITE_OK else {
            throw SQLiteError.queryFailed(Self.errorLabel(queryRC))
        }
        guard let out else { return nil }
        let value = String(cString: out).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func copyDatabaseBundle(from expandedPath: String) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let baseName = URL(fileURLWithPath: expandedPath).lastPathComponent
        let destBase = tempDir.appendingPathComponent(baseName).path
        for suffix in ["", "-wal", "-shm"] {
            let src = expandedPath + suffix
            guard FileManager.default.fileExists(atPath: src) else { continue }
            try FileManager.default.copyItem(atPath: src, toPath: destBase + suffix)
        }
        return destBase
    }

    private static func isBusyOrLocked(_ message: String) -> Bool {
        message.contains("SQLITE_BUSY") || message.contains("SQLITE_LOCKED")
    }

    private static func errorLabel(_ code: Int32) -> String {
        switch code {
        case OU_SQLITE_BUSY: "SQLITE_BUSY"
        case OU_SQLITE_LOCKED: "SQLITE_LOCKED"
        case OU_SQLITE_OK: "SQLITE_OK"
        default: "sqlite_error_\(code)"
        }
    }
}

#else

struct WinSQLiteAccessor: SQLiteAccessing {
    func queryValue(path: String, sql: String) throws -> String? { nil }
    func execute(path: String, sql: String) throws {}
}

#endif

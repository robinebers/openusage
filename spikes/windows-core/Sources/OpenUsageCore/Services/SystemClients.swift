import Foundation

protocol EnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

/// Windows spike: process environment only (no login-shell capture).
struct ProcessEnvironmentReader: EnvironmentReading {
    func value(for name: String) -> String? {
        ProcessInfo.processInfo.environment[name]?.nilIfEmpty
    }
}

protocol TextFileAccessing: Sendable {
    func exists(_ path: String) -> Bool
    func readText(_ path: String) throws -> String
    func writeText(_ path: String, _ text: String) throws
    func remove(_ path: String) throws
}

struct LocalTextFileAccessor: TextFileAccessing {
    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: WellKnownPaths.expandHome(path))
    }

    func readText(_ path: String) throws -> String {
        try String(contentsOfFile: WellKnownPaths.expandHome(path), encoding: .utf8)
    }

    func writeText(_ path: String, _ text: String) throws {
        let expanded = WellKnownPaths.expandHome(path)
        let parent = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try text.write(toFile: expanded, atomically: true, encoding: .utf8)
    }

    func remove(_ path: String) throws {
        let expanded = WellKnownPaths.expandHome(path)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        try FileManager.default.removeItem(atPath: expanded)
    }
}

/// Compatibility alias — spike routes through `WellKnownPaths.expandHome`.
func expandHome(_ path: String) -> String {
    WellKnownPaths.expandHome(path)
}

/// Windows spike: keychain stub for providers that still accept `KeychainAccessing` in their API.
protocol KeychainAccessing: Sendable {
    func readGenericPassword(service: String) throws -> String?
    func writeGenericPassword(service: String, value: String) throws
    func readGenericPasswordForCurrentUser(service: String) throws -> String?
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws
    func readGenericPassword(service: String, account: String) throws -> String?
}

extension KeychainAccessing {
    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writeGenericPassword(service: service, value: value)
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try readGenericPassword(service: service)
    }
}

struct NoOpKeychainAccessor: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? { nil }
    func writeGenericPassword(service: String, value: String) throws {}
    func readGenericPasswordForCurrentUser(service: String) throws -> String? { nil }
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {}
    func readGenericPassword(service: String, account: String) throws -> String? { nil }
}

/// Non-Windows spike stub when no linked SQLite library is available.
struct NoOpSQLiteAccessor: SQLiteAccessing {
    func queryValue(path: String, sql: String) throws -> String? { nil }
    func execute(path: String, sql: String) throws {}
}

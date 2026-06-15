import Foundation

protocol EnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

struct ProcessEnvironmentReader: EnvironmentReading {
    func value(for name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }
}

protocol TextFileAccessing: Sendable {
    func exists(_ path: String) -> Bool
    func readText(_ path: String) throws -> String
    func writeText(_ path: String, _ text: String) throws
}

struct LocalTextFileAccessor: TextFileAccessing {
    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expandHome(path))
    }

    func readText(_ path: String) throws -> String {
        try String(contentsOfFile: expandHome(path), encoding: .utf8)
    }

    func writeText(_ path: String, _ text: String) throws {
        let expanded = expandHome(path)
        let parent = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try text.write(toFile: expanded, atomically: true, encoding: .utf8)
    }
}

protocol SQLiteAccessing: Sendable {
    func queryValue(path: String, sql: String) throws -> String?
    func execute(path: String, sql: String) throws
}

struct SQLiteCLIAccessor: SQLiteAccessing {
    var processRunner: ProcessRunning

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func queryValue(path: String, sql: String) throws -> String? {
        let result = try run(path: path, sql: sql)
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func execute(path: String, sql: String) throws {
        let result = try run(path: path, sql: sql)
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
    }

    private func run(path: String, sql: String) throws -> ProcessResult {
        try processRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: [
                "-batch",
                "-noheader",
                "-cmd", ".timeout 1000",
                expandHome(path),
                sql
            ],
            environment: [:],
            timeout: 5
        )
    }
}

enum SQLiteError: Error, LocalizedError, Equatable {
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .queryFailed(let message):
            return message.isEmpty ? "SQLite query failed." : message
        }
    }
}

protocol KeychainAccessing: Sendable {
    func readGenericPassword(service: String) throws -> String?
    func writeGenericPassword(service: String, value: String) throws
    func readGenericPasswordForCurrentUser(service: String) throws -> String?
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws
}

extension KeychainAccessing {
    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writeGenericPassword(service: service, value: value)
    }
}

struct SecurityKeychainAccessor: KeychainAccessing {
    let processRunner: ProcessRunning

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func readGenericPassword(service: String) throws -> String? {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service, "-w"],
            environment: [:],
            timeout: 5
        )
        guard result.succeeded else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-a", currentUserAccount(), "-s", service, "-w"],
            environment: [:],
            timeout: 5
        )
        guard result.succeeded else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func writeGenericPassword(service: String, value: String) throws {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: ["add-generic-password", "-U", "-s", service, "-w", value],
            environment: [:],
            timeout: 5
        )
        if !result.succeeded {
            throw KeychainError.writeFailed(result.stderr)
        }
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: ["add-generic-password", "-U", "-a", currentUserAccount(), "-s", service, "-w", value],
            environment: [:],
            timeout: 5
        )
        if !result.succeeded {
            throw KeychainError.writeFailed(result.stderr)
        }
    }

    private func currentUserAccount() -> String {
        ProcessInfo.processInfo.environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? NSUserName()
    }
}

enum KeychainError: Error, LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return message.isEmpty ? "Keychain write failed." : message
        }
    }
}

func expandHome(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    return home + String(path.dropFirst())
}


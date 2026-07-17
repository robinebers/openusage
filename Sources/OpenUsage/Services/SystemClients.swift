import CryptoKit
import Darwin
import Foundation

protocol EnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

struct ProcessEnvironmentReader: EnvironmentReading {
    func value(for name: String) -> String? {
        // The process environment first (set by launchd, `launchctl setenv`, or a terminal launch),
        // then the captured login-shell environment — so keys a user exports in their shell profile
        // still resolve in a packaged app launched from Finder/Dock. See `LoginShellEnvironment`.
        if let value = ProcessInfo.processInfo.environment[name]?.nilIfEmpty {
            return value
        }
        return LoginShellEnvironment.shared.value(for: name)
    }
}

/// An environment view pinned to one provider-instance home: the named keys read as the fixed override
/// (a `nil` override hides the key entirely), everything else falls through to `base`. Provider-instance
/// runtimes are scoped with this so a user-exported `CLAUDE_CONFIG_DIR`/`CODEX_HOME`/token env var can
/// only ever affect the default card, never leak another account into an instance.
struct ScopedEnvironmentReader: EnvironmentReading {
    var base: EnvironmentReading
    var overrides: [String: String?]

    func value(for name: String) -> String? {
        if let override = overrides[name] { return override }
        return base.value(for: name)
    }
}

protocol TextFileAccessing: Sendable {
    func exists(_ path: String) -> Bool
    /// Read a UTF-8 file when it exists. `nil` means the path is absent; permission, encoding, and
    /// other failures still throw so credential callers do not confuse broken storage with logout.
    func readTextIfPresent(_ path: String) throws -> String?
    func readText(_ path: String) throws -> String
    func writeText(_ path: String, _ text: String) throws
    /// Remove the file at `path`. A missing file is not an error — the caller wants the key gone, and
    /// it already is. Used by the in-app API-key editor's Remove / Clear-override actions.
    func remove(_ path: String) throws
}

extension TextFileAccessing {
    /// Compatibility path for test doubles. The production accessor classifies the read error directly
    /// so it does not have an exists-then-read race.
    func readTextIfPresent(_ path: String) throws -> String? {
        guard exists(path) else { return nil }
        return try readText(path)
    }
}

struct LocalTextFileAccessor: TextFileAccessing {
    /// Credential and token files must never be readable by another local account. Write through a
    /// private temporary file in the destination directory, flush it, then rename it over the target:
    /// the final replacement is atomic and has mode 0600 from the moment it becomes addressable.
    private static let privateFileMode = mode_t(S_IRUSR | S_IWUSR)

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expandHome(path))
    }

    func readText(_ path: String) throws -> String {
        try String(contentsOfFile: expandHome(path), encoding: .utf8)
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        do {
            return try readText(path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeText(_ path: String, _ text: String) throws {
        let expanded = expandHome(path)
        let parent = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let destination = URL(fileURLWithPath: expanded)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, Self.privateFileMode)
        }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }

        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if temporaryExists {
                temporary.path.withCString { _ = Darwin.unlink($0) }
            }
        }

        // A process umask may only remove permissions at creation. Reassert the exact private mode on
        // the still-unpublished inode before writing or renaming it into place.
        guard Darwin.fchmod(descriptor, Self.privateFileMode) == 0 else {
            throw Self.currentPOSIXError()
        }
        try Self.writeAll(Data(text.utf8), to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw Self.currentPOSIXError() }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw Self.currentPOSIXError() }

        let renameResult = temporary.path.withCString { source in
            expanded.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else { throw Self.currentPOSIXError() }
        temporaryExists = false
    }

    func remove(_ path: String) throws {
        let expanded = expandHome(path)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        try FileManager.default.removeItem(atPath: expanded)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
        // A normal sqlite3 open can create a missing database. Credential probes must be read-only and
        // side-effect free, so absence returns nil before a process is launched.
        guard try databaseExists(path) else { return nil }
        let result = try run(path: path, sql: sql, readOnly: true)
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

    private func run(path: String, sql: String, readOnly: Bool = false) throws -> ProcessResult {
        var arguments = ["-batch", "-noheader"]
        if readOnly { arguments.append("-readonly") }
        arguments += [
            "-cmd", ".timeout 1000",
            expandHome(path),
            sql
        ]
        return try processRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
    }

    private func databaseExists(_ path: String) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: expandHome(path))
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
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
    /// Read a generic password scoped to an explicit account (`-a`). Used when another app stored the
    /// item under a known account name (e.g. Antigravity's `agy` token under service `gemini`,
    /// account `antigravity`) rather than the current user.
    func readGenericPassword(service: String, account: String) throws -> String?
    /// Write a generic password scoped to an explicit account (`-a`), so rotating one instance's item
    /// can never clobber another account's item under the same service (e.g. Codex's per-home
    /// `Codex Auth` entries).
    func writeGenericPassword(service: String, account: String, value: String) throws
    /// Whether an item exists, checked from attributes only — the secret is never requested, so this
    /// can never raise a keychain permission dialog. Provider-instance discovery and first-run
    /// detection use this; any account-scoped secret read happens later, off the launch path. The
    /// production accessor answers `true` when the attributes probe itself fails because callers use
    /// this as a conservative credential-footprint check: unknown must never mean safely absent.
    func hasGenericPassword(service: String, account: String?) -> Bool
    /// Opaque digest of an account-scoped item's non-secret attributes. The production implementation
    /// hashes the complete attributes-only `security` output (including `mdat`) so an in-place item
    /// replacement changes the digest without exposing or persisting any raw keychain metadata.
    /// `nil` means the item is absent, the probe failed, or this accessor cannot provide a
    /// version-sensitive fingerprint.
    func genericPasswordAttributeFingerprint(service: String, account: String) -> String?
}

extension KeychainAccessing {
    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writeGenericPassword(service: service, value: value)
    }

    /// Default for mocks that don't model accounts: fall back to the service-only lookup. The real
    /// `SecurityKeychainAccessor` overrides this to pass `-a <account>`.
    func readGenericPassword(service: String, account: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    /// Default for mocks that don't model accounts: fall back to the service-only write.
    func writeGenericPassword(service: String, account: String, value: String) throws {
        try writeGenericPassword(service: service, value: value)
    }

    /// Default for mocks: existence follows the read paths, so a mock seeded with `readGenericPassword`
    /// values answers correctly. The real accessor overrides this with an attributes-only query.
    func hasGenericPassword(service: String, account: String?) -> Bool {
        if let account {
            return ((try? readGenericPassword(service: service, account: account)) ?? nil) != nil
        }
        return ((try? readGenericPassword(service: service)) ?? nil) != nil
    }

    func genericPasswordAttributeFingerprint(service: String, account: String) -> String? {
        nil
    }
}

struct SecurityKeychainAccessor: KeychainAccessing {
    let processRunner: ProcessRunning
    /// Attribute-only discovery probes run on the launch path. Keep their subprocess bound separate
    /// from secret reads/writes, which may legitimately wait for Keychain interaction.
    let attributeProbeTimeout: TimeInterval

    init(
        processRunner: ProcessRunning = SystemProcessRunner(),
        attributeProbeTimeout: TimeInterval = 0.25
    ) {
        self.processRunner = processRunner
        self.attributeProbeTimeout = attributeProbeTimeout
    }

    // `security find-generic-password` exits 44 (errSecItemNotFound) when no item matches — the
    // legitimate "no credential stored" case. Any OTHER non-zero exit means a real failure (keychain
    // locked or access denied, a cancelled unlock prompt) that must not be silently rendered as
    // "not signed in".
    private static let itemNotFoundExitCode: Int32 = 44

    func readGenericPassword(service: String) throws -> String? {
        try readPassword(["find-generic-password", "-s", service, "-w"], service: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readPassword(["find-generic-password", "-a", currentUserAccount(), "-s", service, "-w"], service: service)
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try readPassword(["find-generic-password", "-a", account, "-s", service, "-w"], service: service)
    }

    private func readPassword(_ arguments: [String], service: String) throws -> String? {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
        guard result.succeeded else {
            if result.exitCode == Self.itemNotFoundExitCode { return nil }
            // Log loudly here so a locked/denied keychain is diagnosable even though current callers
            // `try?` this back to nil ("not signed in"). Surfacing a distinct user-facing "keychain
            // locked" message needs the auth-load chains to propagate the throw (folded into H1).
            AppLog.warn(.keychain, "read failed for service '\(service)' (exit \(result.exitCode))")
            throw KeychainError.readFailed(result.stderr)
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func writeGenericPassword(service: String, value: String) throws {
        try writePassword(["add-generic-password", "-U", "-s", service, "-w", value])
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writePassword(["add-generic-password", "-U", "-a", currentUserAccount(), "-s", service, "-w", value])
    }

    func writeGenericPassword(service: String, account: String, value: String) throws {
        try writePassword(["add-generic-password", "-U", "-a", account, "-s", service, "-w", value])
    }

    func hasGenericPassword(service: String, account: String?) -> Bool {
        // No `-w`: attributes only, so the item's ACL is never consulted and no permission dialog can
        // appear. Exit 44 (errSecItemNotFound) is the clean "no item". A timeout or any other failure
        // is an unknown footprint and therefore returns true: launch discovery must suppress a base
        // conservatively instead of treating a wedged/locked keychain as proof that no default exists.
        var arguments = ["find-generic-password"]
        if let account { arguments += ["-a", account] }
        arguments += ["-s", service]
        do {
            let result = try processRunner.run(
                executable: "/usr/bin/security",
                arguments: arguments,
                environment: [:],
                timeout: attributeProbeTimeout
            )
            if result.succeeded { return true }
            if result.exitCode == Self.itemNotFoundExitCode { return false }
            AppLog.warn(.keychain, "attribute probe failed for service '\(service)' (exit \(result.exitCode)); treating its footprint as unknown")
            return true
        } catch {
            AppLog.warn(.keychain, "attribute probe failed for service '\(service)' (\(error)); treating its footprint as unknown")
            return true
        }
    }

    func genericPasswordAttributeFingerprint(service: String, account: String) -> String? {
        // No `-w`: the subprocess returns metadata only, never the secret. Hash before returning so
        // callers cannot accidentally persist a keychain path, account, date, or other raw attribute.
        let arguments = ["find-generic-password", "-a", account, "-s", service]
        guard let result = try? processRunner.run(
            executable: "/usr/bin/security",
            arguments: arguments,
            environment: [:],
            timeout: attributeProbeTimeout
        ) else { return nil }
        guard result.succeeded else {
            if result.exitCode != Self.itemNotFoundExitCode {
                AppLog.warn(.keychain, "attribute fingerprint probe failed for service '\(service)' (exit \(result.exitCode))")
            }
            return nil
        }
        let attributes = result.stdout + "\n" + result.stderr
        guard !attributes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A successful but empty response cannot prove item continuity, so treat it as
            // unverifiable rather than minting the same fingerprint for every keychain item.
            return nil
        }
        return SHA256.hash(data: Data(attributes.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func writePassword(_ arguments: [String]) throws {
        let result = try processRunner.run(
            executable: "/usr/bin/security",
            arguments: arguments,
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
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return message.isEmpty ? "Keychain write failed." : message
        case .readFailed(let message):
            return message.isEmpty ? "Keychain read failed." : message
        }
    }
}

func expandHome(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    return home + String(path.dropFirst())
}

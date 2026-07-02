import Foundation

struct AccountLoginSpec: Sendable {
    let program: String
    let arguments: [String]
    let envVar: String
}

enum AccountLoginError: Error, LocalizedError {
    case unsupported(String)
    case cliNotFound(String)
    case loginFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let provider): return "\(provider) doesn't support in-app login."
        case .cliNotFound(let program): return "`\(program)` CLI not found. Install it, then try again."
        case .loginFailed(let message): return message.isEmpty ? "Login failed. Try again." : message
        }
    }
}

/// Logs a provider CLI into a specific config dir so an additional account's credentials land there
/// (read back later via `CLAUDE_CONFIG_DIR` / `CODEX_HOME`). The CLI itself drives the browser OAuth
/// flow and exits when it completes. Ported from the Tauri edition's `account_login.rs`.
enum AccountLogin {
    static func spec(for provider: String) -> AccountLoginSpec? {
        switch provider {
        case "claude": return AccountLoginSpec(program: "claude", arguments: ["auth", "login", "--claudeai"], envVar: "CLAUDE_CONFIG_DIR")
        case "codex": return AccountLoginSpec(program: "codex", arguments: ["login"], envVar: "CODEX_HOME")
        default: return nil
        }
    }

    /// Where a newly logged-in account's config (credentials) is kept, isolated from the default login.
    static func defaultConfigDir(provider: String, slot: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.openusage/accounts/\(provider)-\(slot)"
    }

    /// Runs the login off the main thread (it blocks up to 5 minutes while the user completes the
    /// browser OAuth). Throws a friendly error on failure.
    static func run(provider: String, configDir: String, runner: ProcessRunning = SystemProcessRunner()) async throws {
        guard let spec = spec(for: provider) else { throw AccountLoginError.unsupported(provider) }
        let dir = expandHome(configDir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let result = try await Task.detached(priority: .userInitiated) { () throws -> ProcessResult in
            guard let program = resolveProgram(spec.program) else {
                throw AccountLoginError.cliNotFound(spec.program)
            }
            AppLog.info(.subprocess, "account login: \(spec.program) → \(spec.envVar)")
            return try runner.run(
                executable: program,
                arguments: spec.arguments,
                environment: [spec.envVar: dir],
                timeout: 300
            )
        }.value

        guard result.succeeded else {
            let lastLine = result.stderr
                .split(whereSeparator: \.isNewline)
                .last
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            throw AccountLoginError.loginFailed(lastLine ?? "")
        }
    }

    // MARK: - CLI resolution

    /// Finds the provider CLI. GUI apps get a minimal PATH on macOS, so common install locations and
    /// the login shell are also consulted.
    private static func resolveProgram(_ program: String) -> String? {
        var dirs: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        dirs.append(contentsOf: ["\(home)/.local/bin", "\(home)/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
        for dir in dirs where !dir.isEmpty {
            let candidate = "\(dir)/\(program)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        for shell in ["/bin/zsh", "/bin/bash"] {
            if let resolved = shellResolved(shell: shell, program: program) {
                return resolved
            }
        }
        AppLog.warn(.config, "could not resolve CLI '\(program)' on PATH or via a login shell")
        return nil
    }

    private static func shellResolved(shell: String, program: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v \(program)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLog.debug(.config, "shell resolve via \(shell) failed for \(program): \(error.localizedDescription)")
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = output.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty,
              FileManager.default.isExecutableFile(atPath: line)
        else { return nil }
        return line
    }
}

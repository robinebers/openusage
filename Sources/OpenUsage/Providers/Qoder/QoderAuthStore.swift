import Foundation

struct QoderAuth: Hashable, Sendable {
    enum Method: Hashable, Sendable {
        case qodercli
        case accessToken(String)
    }

    var executable: String
    var method: Method
}

enum QoderAuthLoadResult: Equatable {
    case authenticated(QoderAuth)
    case missingCLI
    case notLoggedIn
    case statusUnavailable
}

enum QoderAuthError: Error, LocalizedError, Equatable {
    case missingCLI
    case notLoggedIn
    case statusUnavailable

    var errorDescription: String? {
        switch self {
        case .missingCLI:
            return "Qoder CLI not installed. Install qodercli from qoder.com and sign in."
        case .notLoggedIn:
            return "Qoder is not logged in. Run qodercli login or set QODER_PERSONAL_ACCESS_TOKEN."
        case .statusUnavailable:
            return "Qoder CLI status unavailable. Try updating qodercli."
        }
    }
}

struct QoderAuthStore: Sendable {
    static let personalAccessTokenEnvironmentName = "QODER_PERSONAL_ACCESS_TOKEN"
    static let cliPathEnvironmentName = "QODERCLI_PATH"

    var environment: EnvironmentReading
    var processRunner: ProcessRunning
    var fileManager: FileManagerAccessing
    var loginShellPath: @Sendable () -> String?

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        processRunner: ProcessRunning = SystemProcessRunner(),
        fileManager: FileManagerAccessing = LocalFileManagerAccessor(),
        loginShellPath: @escaping @Sendable () -> String? = { LoginShellEnvironment.shared.value(for: "PATH") }
    ) {
        self.environment = environment
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.loginShellPath = loginShellPath
    }

    func loadAuth() -> QoderAuthLoadResult {
        guard let executable = resolveExecutable() else { return .missingCLI }

        switch status(for: executable) {
        case .loggedIn:
            return .authenticated(QoderAuth(executable: executable, method: .qodercli))
        case .missingCLI:
            return .missingCLI
        case .notLoggedIn:
            if let token = personalAccessToken() {
                return .authenticated(QoderAuth(executable: executable, method: .accessToken(token)))
            }
            return .notLoggedIn
        case .unavailable:
            if let token = personalAccessToken() {
                return .authenticated(QoderAuth(executable: executable, method: .accessToken(token)))
            }
            return .statusUnavailable
        }
    }

    private enum CLIStatus {
        case loggedIn
        case notLoggedIn
        case missingCLI
        case unavailable
    }

    private func status(for executable: String) -> CLIStatus {
        do {
            let result = try processRunner.run(
                executable: executable,
                arguments: ["status", "--output", "json"],
                environment: [:],
                timeout: 5
            )
            guard result.succeeded else {
                if result.exitCode == 127 { return .missingCLI }
                if let status = decodeStatus(from: result.stdout), !status.loggedIn { return .notLoggedIn }
                AppLog.warn(LogTag.auth("qoder"), "qodercli status exited \(result.exitCode)")
                return .unavailable
            }
            guard let status = decodeStatus(from: result.stdout) else {
                AppLog.warn(LogTag.auth("qoder"), "qodercli status returned invalid JSON")
                return .unavailable
            }
            return status.loggedIn ? .loggedIn : .notLoggedIn
        } catch ProcessRunnerError.timedOut(_, _) {
            AppLog.warn(LogTag.auth("qoder"), "qodercli status timed out")
            return .unavailable
        } catch {
            AppLog.warn(LogTag.auth("qoder"), "qodercli status failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    private func resolveExecutable() -> String? {
        if let configured = environment.value(for: Self.cliPathEnvironmentName)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let expanded = expandHome(configured)
            return fileManager.isExecutableFile(expanded) ? expanded : nil
        }

        for directory in executableSearchDirectories() {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("qodercli").path
            if fileManager.isExecutableFile(candidate) { return candidate }
        }

        for candidate in commonExecutablePaths() where fileManager.isExecutableFile(candidate) {
            return candidate
        }

        return "qodercli"
    }

    private func commonExecutablePaths() -> [String] {
        var paths = [
            "~/.local/bin/qodercli",
            "/opt/homebrew/bin/qodercli",
            "/usr/local/bin/qodercli"
        ].map(expandHome)

        let versionedDir = expandHome("~/.qoder/bin/qodercli")
        if let entries = try? fileManager.contentsOfDirectory(versionedDir) {
            paths.append(contentsOf: entries
                .filter { $0.hasPrefix("qodercli-") }
                .sorted()
                .reversed()
                .map { URL(fileURLWithPath: versionedDir).appendingPathComponent($0).path })
        }

        return paths
    }

    private func personalAccessToken() -> String? {
        environment.value(for: Self.personalAccessTokenEnvironmentName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func executableSearchDirectories() -> [String] {
        var seen: Set<String> = []
        return [environment.value(for: "PATH"), loginShellPath()]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .flatMap { $0.split(separator: ":").map(String.init) }
            .filter { seen.insert($0).inserted }
    }

    private func decodeStatus(from stdout: String) -> QoderStatus? {
        guard let data = stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QoderStatus.self, from: data)
    }
}

private struct QoderStatus: Decodable {
    let loggedIn: Bool

    private enum CodingKeys: String, CodingKey {
        case loggedIn = "logged_in"
    }
}

protocol FileManagerAccessing: Sendable {
    func isExecutableFile(_ path: String) -> Bool
    func contentsOfDirectory(_ path: String) throws -> [String]
}

struct LocalFileManagerAccessor: FileManagerAccessing {
    func isExecutableFile(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func contentsOfDirectory(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }
}

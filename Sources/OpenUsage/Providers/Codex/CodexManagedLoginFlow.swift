import Foundation

/// Runs the CLI and proves what it signed in as (off the main actor), and publishes a login into a
/// managed home (`moveAuth`, called on the main actor, where it may wait for the home's lock).
/// Immutable, so it needs no locking; the per-operation URL callback travels with each call.
struct CodexManagedLoginFlow: Sendable {
    static let timeout: TimeInterval = 15 * 60

    private let launcher: any CodexLoginLaunching
    private let files: any TextFileAccessing
    private let shellPATH: @Sendable () -> String?
    private let processEnvironment: [String: String]
    private let homeDirectory: URL

    init(
        launcher: any CodexLoginLaunching, files: any TextFileAccessing,
        shellPATH: @escaping @Sendable () -> String?, processEnvironment: [String: String], homeDirectory: URL
    ) {
        self.launcher = launcher
        self.files = files
        self.shellPATH = shellPATH
        self.processEnvironment = processEnvironment
        self.homeDirectory = homeDirectory
    }

    /// Runs `codex login` with `CODEX_HOME` at `home` and returns the verified account identity.
    func signIn(home: URL, onURL: @escaping @Sendable (String) -> Void) async throws -> CodexAccountIdentity {
        let searchPath = await Task.detached(priority: .userInitiated) { [shellPATH, processEnvironment, homeDirectory] in
            CodexExecutableLocator.searchPath(
                shellPATH: shellPATH(), processPATH: processEnvironment["PATH"], home: homeDirectory
            )
        }.value
        try Task.checkCancellation()
        guard let executable = CodexExecutableLocator.locate(searchPath: searchPath) else {
            throw CodexManagedLoginError.codexNotInstalled
        }
        var environment = processEnvironment
        environment["CODEX_HOME"] = home.path
        environment["PATH"] = searchPath.joined(separator: ":")
        let output = CodexLoginOutput(onURL: onURL)
        let status = try await launcher.runLogin(
            executable: executable,
            // The config override keeps the login in this home's auth.json; a Keychain login would
            // belong to a different lookup and leave the managed home empty.
            arguments: ["login", "-c", "cli_auth_credentials_store=\"file\""],
            environment: environment,
            timeout: Self.timeout,
            onOutput: { output.append($0) }
        )
        try Task.checkCancellation()
        guard status == 0 else {
            // The CLI's error line is for the user, never for the log: a wrapper's message can name
            // the account or carry a token. The service logs the payload-free code (the exit status).
            throw CodexManagedLoginError.loginFailed(exitCode: status, detail: output.diagnosticLine)
        }
        return try identity(home: home)
    }

    func identity(home: URL) throws -> CodexAccountIdentity {
        guard let text = try files.readTextIfPresent(home.appendingPathComponent("auth.json").path),
              let auth = CodexAuthStore.parseAuth(text)
        else { throw CodexManagedLoginError.noLogin }
        guard auth.tokens?.accessToken?.nilIfEmpty != nil else {
            throw auth.apiKey?.nilIfEmpty != nil ? CodexManagedLoginError.apiKeyOnly : CodexManagedLoginError.noLogin
        }
        guard let identity = CodexAccountIdentity(auth: auth),
              CodexAccountIdentity.isComplete(key: identity.key)
        else { throw CodexManagedLoginError.incompleteIdentity }
        return identity
    }

    /// Publishes a freshly written `auth.json` into another managed home through the private atomic
    /// writer, so the destination never holds a half-written credential — and under the home's
    /// lock, so a token rotation of the old login that is mid-write (in this app or in the
    /// `openusage` CLI) cannot overwrite the new one.
    func moveAuth(from source: URL, to destination: URL) throws {
        let text = try files.readText(source.appendingPathComponent("auth.json").path)
        let destinationPath = destination.appendingPathComponent("auth.json").path
        try files.withExclusiveAccess(toDirectoryOf: destinationPath) {
            try files.writeText(destinationPath, text)
        }
    }
}

/// Reassembles the CLI's output from whatever pipe-sized chunks arrive: reports the sign-in page
/// once, only after a whitespace boundary proves the URL is complete, and keeps the CLI's error line
/// so a failed login can say why (a port already in use, an OAuth error) instead of just "exit 1".
final class CodexLoginOutput: @unchecked Sendable {
    private static let maximumBuffer = 64 * 1024
    private let lock = NSLock()
    private var buffer = ""
    private var reported = false
    private let onURL: @Sendable (String) -> Void

    init(onURL: @escaping @Sendable (String) -> Void) { self.onURL = onURL }

    func append(_ chunk: String) {
        lock.lock()
        buffer += chunk
        if buffer.count > Self.maximumBuffer { buffer = String(buffer.suffix(Self.maximumBuffer / 2)) }
        guard !reported, let url = Self.completeSignInURL(in: buffer) else {
            lock.unlock()
            return
        }
        reported = true
        lock.unlock()
        onURL(url)
    }

    /// The last line that reads like a CLI error, with ANSI coloring and any URL removed so it is
    /// safe to show. Not safe to log: it is the CLI's own text and may carry an email or a token.
    var diagnosticLine: String? {
        lock.lock()
        defer { lock.unlock() }
        return Self.diagnosticLine(in: buffer)
    }

    /// The first `https://auth.openai.com/…` link followed by whitespace or an escape code. ANSI
    /// coloring around the link does not break the match.
    static func completeSignInURL(in text: String) -> String? {
        text.firstMatch(of: /https:\/\/auth\.openai\.com\/[^\s\u{1B}]+(?=[\s\u{1B}])/).map { String($0.output) }
    }

    static func diagnosticLine(in text: String) -> String? {
        let plain = text.replacing(/\u{1B}\[[0-9;]*m/, with: "")
        return plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("Error") || $0.hasPrefix("error") || $0.contains("already in use") }
            .map { $0.replacing(/https?:\/\/\S+/, with: "<url>") }
    }
}

import Foundation

/// A macOS GUI app launched from Finder, the Dock, or `open` inherits only the launchd session
/// environment — not the variables a user exports in their interactive login shell
/// (`~/.zshrc`, `~/.zprofile`, `~/.bash_profile`). Provider keys like `OPENROUTER_API_KEY` live
/// there, so without this they are invisible to a packaged build; they only resolved when the
/// binary was run straight from a terminal during development (which is why "it worked in dev"
/// but not in the shipped beta).
///
/// This captures the login shell environment once, by running the user's `$SHELL` as a login +
/// interactive shell and reading its `env`, then caches the result. `ProcessEnvironmentReader`
/// consults it as a fallback after the process environment, so env-var keys resolve in the
/// bundled app the same way they do from a terminal.
///
/// Threading: the capture subprocess never runs (or is waited on) while the state lock is held, so
/// a cache read can't stall behind it. The **main thread** never triggers the capture — it reads
/// whatever is cached and otherwise returns `nil`, so opening a provider's API-key editor before the
/// cache warms can't freeze the UI. Off-main callers (provider refreshes) capture on demand and block
/// only for the single, one-time spawn, so the first refresh still resolves the key. `prewarm()` kicks the
/// capture at launch so the cache is normally warm before anything reads it.
final class LoginShellEnvironment: @unchecked Sendable {
    static let shared = LoginShellEnvironment()

    /// Sentinel tokens that bracket our `env` output, so a login shell's banner/MOTD (printed before
    /// our command runs) is discarded instead of mis-parsed as variables.
    private static let beginMarker = "__OPENUSAGE_ENV_BEGIN__"
    private static let endMarker = "__OPENUSAGE_ENV_END__"
    /// Cap the shell spawn so a slow or hanging profile can't stall a provider refresh forever.
    private static let captureTimeout: TimeInterval = 5

    private let runner: ProcessRunning
    /// Guards `cached` only — held for microseconds, never across the subprocess.
    private let stateLock = NSLock()
    /// Serializes the capture so a single subprocess runs even under concurrent callers. Taken only
    /// off the main thread (see `value(for:)`), so the UI thread can never wait on it.
    private let captureLock = NSLock()
    private var cached: [String: String]?

    init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    /// The captured login-shell value for `name`, or `nil` if absent or empty. Never blocks the main
    /// thread on the subprocess: on the main thread it only reads the cache, returning `nil` until the
    /// prewarm fills it; off the main thread it captures on demand if needed.
    func value(for name: String) -> String? {
        if let env = cachedSnapshot() { return env[name]?.nilIfEmpty }
        guard !Thread.isMainThread else { return nil }
        return capturedEnvironment()[name]?.nilIfEmpty
    }

    /// Spawn the capture eagerly off the main thread so the first provider refresh (and any UI read)
    /// finds the cache already warm and never blocks on the subprocess. Safe to call more than once.
    /// `.userInitiated`, not `.utility`: launch-time readers depend on this cache, and under
    /// cold-launch CPU contention a utility-priority spawn regularly lost the race against the first
    /// provider refresh — which then resolved shell-exported keys as absent for the whole pass.
    func prewarm() {
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = self?.capturedEnvironment()
        }
    }

    /// Whether a capture has completed AND yielded a plausible environment. A real login shell always
    /// exports at least `PATH`/`HOME`, so an empty capture means the spawn or parse failed — callers
    /// must not persist facts (like "no overrides exported") derived from it.
    var capturedSuccessfully: Bool {
        !(cachedSnapshot() ?? [:]).isEmpty
    }

    /// Off-main only: make sure the one-time capture has actually run (spawning it now if the prewarm
    /// never completed), then report whether it succeeded. The post-launch snapshot task uses this so
    /// a launch whose prewarm was slow still persists fresh facts for the next launch.
    func ensureCaptured() -> Bool {
        guard !Thread.isMainThread else { return capturedSuccessfully }
        _ = capturedEnvironment()
        return capturedSuccessfully
    }

    private func cachedSnapshot() -> [String: String]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cached
    }

    /// Capture the environment once and cache it. Off-main only. Serialized by `captureLock` so a
    /// single subprocess runs; the spawn happens with no lock held, and the result is stored under a
    /// brief `stateLock` so concurrent cache reads never block on the subprocess.
    private func capturedEnvironment() -> [String: String] {
        captureLock.lock()
        defer { captureLock.unlock() }
        if let env = cachedSnapshot() { return env }
        let captured = capture()
        stateLock.lock()
        cached = captured
        stateLock.unlock()
        return captured
    }

    private func capture() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"]?.nilIfEmpty ?? "/bin/zsh"
        // `-i -l -c`: interactive + login so both rc files (.zshrc/.bashrc) and profile files
        // (.zprofile/.bash_profile) are sourced; `env -0` emits NUL-separated `KEY=VALUE`, robust
        // against values that contain newlines.
        let command = "printf '%s\\0' \(Self.beginMarker); /usr/bin/env -0; printf '%s\\0' \(Self.endMarker)"
        do {
            let result = try runner.run(
                executable: shell,
                arguments: ["-ilc", command],
                environment: [:],
                timeout: Self.captureTimeout
            )
            guard result.succeeded else {
                AppLog.warn(.subprocess, "login-shell env capture exited \(result.exitCode)")
                return [:]
            }
            return Self.parse(result.stdout)
        } catch {
            AppLog.warn(.subprocess, "login-shell env capture failed: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Parse the NUL-separated `env -0` output, keeping only the `KEY=VALUE` tokens between the begin
    /// and end markers and ignoring any shell banner printed outside them.
    static func parse(_ output: String) -> [String: String] {
        let tokens = output.components(separatedBy: "\0")
        guard let begin = tokens.firstIndex(of: beginMarker) else { return [:] }
        let end = tokens.firstIndex(of: endMarker) ?? tokens.count
        guard begin < end else { return [:] }

        var environment: [String: String] = [:]
        for token in tokens[(begin + 1)..<end] {
            guard let separator = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<separator])
            guard !key.isEmpty else { continue }
            environment[key] = String(token[token.index(after: separator)...])
        }
        return environment
    }
}

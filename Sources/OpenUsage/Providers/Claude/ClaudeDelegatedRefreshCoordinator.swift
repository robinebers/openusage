import Foundation
import os

/// Delegates an OAuth token refresh to the `claude` CLI when OpenUsage's own stored refresh token is
/// missing or revoked. The CLI owns the refresh token and client credentials OpenUsage never sees, so
/// touching it can rotate the access token in the keychain/file that OpenUsage reads. This is the
/// backstop for #738/#753: the credential source OpenUsage reads has no usable refresh token, so it can
/// never self-heal — but the `claude` CLI can.
///
/// The touch is a NON-INTERACTIVE `claude --version` (owner decision). We do not assume `--version`
/// rotates the token; instead we fingerprint the stored credential before and after and treat the
/// attempt as successful ONLY when the fingerprint changed. If `--version` proves insufficient in
/// practice (it doesn't trigger a refresh), the escalation is a PTY-driven `claude /status`.
//
// TODO(#753): if a non-interactive `claude --version` does not reliably trigger the CLI's lazy token
// refresh in the field, escalate to a PTY session running `claude /status` (the CLI refreshes its token
// on an interactive status check). That requires a pseudo-terminal, which this coordinator deliberately
// avoids for now — we rely on the fingerprint-changed check to confirm rotation either way.
struct ClaudeDelegatedRefreshCoordinator: Sendable {
    enum Outcome: Equatable, Sendable {
        case skippedByCooldown
        case cliUnavailable
        case attemptedSucceeded
        case attemptedFailed(String)
    }

    /// Cooldown after a touch that DID rotate the token: a successful delegated refresh is good for a
    /// while, so don't re-touch the CLI on every refresh.
    static let successCooldown: TimeInterval = 5 * 60
    /// Short cooldown reserved under lock the moment an attempt starts (and kept when the touch ran but
    /// didn't rotate), so concurrent/rapid refreshes don't stampede the CLI.
    static let shortCooldown: TimeInterval = 20
    static let touchTimeout: TimeInterval = 8
    /// Delays (seconds) at which we re-read the credential after the touch to see whether it rotated.
    static let verifyPollDelays: [TimeInterval] = [0.2, 0.5, 0.8]

    private let processRunner: ProcessRunning
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let claudeConfigDir: @Sendable () -> String?
    /// Re-reads the CURRENT on-disk credential fingerprint (baseline before the touch, and again after).
    private let currentFingerprint: @Sendable () -> ClaudeCredentialFingerprint
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let isExecutable: @Sendable (String) -> Bool

    private let store: SendableUserDefaults
    private let lastAttemptKey: String
    private let cooldownKey: String

    private var defaults: UserDefaults { store.defaults }

    /// Single-flight: a touch already running shares its in-flight `Task` with concurrent callers rather
    /// than launching the CLI twice. Lock-backed so the value-type coordinator coordinates across calls.
    private let inFlight = OSAllocatedUnfairLock<Task<Outcome, Never>?>(initialState: nil)

    init(
        processRunner: ProcessRunning = SystemProcessRunner(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        claudeConfigDir: @escaping @Sendable () -> String? = { nil },
        currentFingerprint: @escaping @Sendable () -> ClaudeCredentialFingerprint,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        defaults: UserDefaults = .standard,
        lastAttemptKey: String = "claude.delegatedRefresh.lastAttemptAt.v1",
        cooldownKey: String = "claude.delegatedRefresh.cooldownSeconds.v1"
    ) {
        self.processRunner = processRunner
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.claudeConfigDir = claudeConfigDir
        self.currentFingerprint = currentFingerprint
        self.now = now
        self.sleep = sleep
        self.isExecutable = isExecutable
        self.store = SendableUserDefaults(defaults)
        self.lastAttemptKey = lastAttemptKey
        self.cooldownKey = cooldownKey
    }

    /// Attempt a delegated refresh. Short-circuits to `.cliUnavailable` (without consuming the cooldown)
    /// when no `claude` binary resolves; to `.skippedByCooldown` while a prior attempt's cooldown is
    /// active. Otherwise touches the CLI and reports whether the stored credential actually rotated.
    func attempt(now currentTime: Date? = nil) async -> Outcome {
        let moment = currentTime ?? now()

        // Resolve the CLI BEFORE consuming any cooldown — a missing binary isn't a "we tried" event, so
        // it must not burn the cooldown window (the gate, not the cooldown, decides whether to keep
        // re-checking for the CLI).
        guard let cliPath = resolveCLI() else {
            return .cliUnavailable
        }

        // Reserve, cooldown-check, and single-flight in ONE locked step so concurrent callers can't race
        // between "is a launch in flight?" and "create the launch":
        //   - a launch already in flight → share its Task (single-flight),
        //   - else inside an active cooldown → skip,
        //   - else stamp a short cooldown and create the one Task the racers share.
        enum Reservation { case share(Task<Outcome, Never>); case cooldown }
        let reservation: Reservation = inFlight.withLock { task in
            if let task { return .share(task) }
            if isInCooldown(now: moment) { return .cooldown }
            stampCooldown(seconds: Self.shortCooldown, now: moment)
            let created = Task<Outcome, Never> { await self.runTouchAndVerify(cliPath: cliPath, now: moment) }
            task = created
            return .share(created)
        }

        switch reservation {
        case .cooldown:
            return .skippedByCooldown
        case .share(let task):
            let outcome = await task.value
            // Only the owner clears the in-flight slot (idempotent: a shared racer clearing it again is
            // harmless because by then a new attempt would already have created a fresh Task).
            inFlight.withLock { if $0 == task { $0 = nil } }
            return outcome
        }
    }

    // MARK: - Touch + verify

    private func runTouchAndVerify(cliPath: String, now moment: Date) async -> Outcome {
        let baseline = currentFingerprint()
        AppLog.info(LogTag.auth("claude"), "delegated refresh: touching claude CLI")

        var environment = enrichedPathEnvironment()
        if let configDir = claudeConfigDir(), !configDir.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = (configDir as NSString).expandingTildeInPath
        }

        do {
            // Output is discarded — we only care whether the touch rotated the credential. `--version`
            // is non-interactive and side-effect-light; the verify step is what confirms a rotation.
            _ = try processRunner.run(
                executable: cliPath,
                arguments: ["--version"],
                environment: environment,
                timeout: Self.touchTimeout
            )
        } catch {
            AppLog.warn(LogTag.auth("claude"), "delegated refresh: claude CLI touch failed: \(LogRedaction.redactLogMessage(error.localizedDescription))")
            // The touch itself failed (timeout/launch error). Keep the short cooldown already stamped.
            return .attemptedFailed("touch failed")
        }

        // Poll the credential a few times — the CLI may write asynchronously just after exit.
        for delay in Self.verifyPollDelays {
            await sleep(delay)
            if currentFingerprint() != baseline {
                // Stamp the success cooldown with the same `moment` time source used for the short
                // cooldown at attempt start, not `now()` — callers that inject time via
                // `attempt(now:)` would otherwise get mismatched cooldown timestamps (bugbot
                // #ed400fe6). The verify polls don't advance the injected clock in tests, and in
                // production `moment == now()` so the ~1.5s of poll delay is negligible vs the 5-min
                // cooldown.
                stampCooldown(seconds: Self.successCooldown, now: moment)
                AppLog.info(LogTag.auth("claude"), "delegated refresh: credential rotated (success)")
                return .attemptedSucceeded
            }
        }

        AppLog.info(LogTag.auth("claude"), "delegated refresh: credential unchanged after touch")
        return .attemptedFailed("credential unchanged")
    }

    // MARK: - Cooldown

    /// Whether the coordinator could attempt a delegated refresh right now — the CLI resolves AND
    /// no cooldown is active. Used by the provider's terminal-block short-circuit to decide whether
    /// to skip the refresh entirely or let it proceed so the CLI gets a chance to rotate the
    /// credential (e.g. after the user installed the CLI or the coordinator cooldown expired). Does
    /// NOT touch the CLI or consume the cooldown — purely a probe.
    func canAttempt(now: Date) -> Bool {
        guard resolveCLI() != nil else { return false }
        return !isInCooldown(now: now)
    }

    private func isInCooldown(now moment: Date) -> Bool {
        guard defaults.object(forKey: lastAttemptKey) != nil else { return false }
        let last = Date(timeIntervalSince1970: defaults.double(forKey: lastAttemptKey))
        let cooldown = defaults.double(forKey: cooldownKey)
        guard cooldown > 0 else { return false }
        return moment.timeIntervalSince(last) < cooldown
    }

    private func stampCooldown(seconds: TimeInterval, now moment: Date) {
        defaults.set(moment.timeIntervalSince1970, forKey: lastAttemptKey)
        defaults.set(seconds, forKey: cooldownKey)
    }

    // MARK: - CLI resolution

    /// Resolve the `claude` binary, honoring `CLAUDE_CLI_PATH`, then a fixed set of install locations,
    /// then a bare `claude` probed against the enriched PATH (a GUI app inherits a stripped PATH).
    func resolveCLI() -> String? {
        if let override = environment.value(for: "CLAUDE_CLI_PATH")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return isExecutable(expanded) ? expanded : nil
        }
        let home = homeDirectory()
        let absoluteCandidates = [
            home.appendingPathComponent(".claude/local/claude").path,
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        for candidate in absoluteCandidates where isExecutable(candidate) {
            return candidate
        }
        return commandExists("claude") ? "claude" : nil
    }

    private func commandExists(_ command: String) -> Bool {
        // Use `/usr/bin/which` to check PATH presence WITHOUT running `claude` — running
        // `claude --version` here would be a side-effecting probe that could rotate the credential
        // BEFORE `runTouchAndVerify` captures its baseline fingerprint, making the probe's rotation
        // look like the baseline and the second touch look unchanged (bugbot #d30aea11). `which`
        // only resolves the path; the actual `--version` touch (and its fingerprint verification)
        // happens in `runTouchAndVerify`.
        do {
            let result = try processRunner.run(
                executable: "/usr/bin/which",
                arguments: [command],
                environment: enrichedPathEnvironment(),
                timeout: 2
            )
            // `which` exits 0 and prints the resolved path when the command is on PATH.
            return result.succeeded && !result.stdout.isEmpty
        } catch {
            return false
        }
    }

    private func enrichedPathEnvironment() -> [String: String] {
        ["PATH": CcusageRunner.pathEntries(
            home: homeDirectory(),
            existingPath: ProcessInfo.processInfo.environment["PATH"]
        ).joined(separator: ":")]
    }
}

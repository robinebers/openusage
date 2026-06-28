import XCTest
@testable import OpenUsage

final class ClaudeDelegatedRefreshCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "claude.delegatedRefresh.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// Records every launch and counts only the non-`--version`-probe ones... but the touch IS
    /// `--version`, so this counter records ALL launches and we assert on the touch separately. The
    /// optional `onTouch` hook lets a test mutate state (e.g. rotate the fingerprint) when the CLI runs.
    private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var launches: [(executable: String, arguments: [String])] = []
        var resolvableExecutables: Set<String>
        let onTouch: (@Sendable () -> Void)?

        init(resolvableExecutables: Set<String>, onTouch: (@Sendable () -> Void)? = nil) {
            self.resolvableExecutables = resolvableExecutables
            self.onTouch = onTouch
        }

        /// The CLI touch always runs an ABSOLUTE resolved path with `--version`; a bare-`claude` PATH
        /// probe (no leading `/`) also runs `--version` but is resolution, not a touch — so exclude it.
        var touchCount: Int {
            lock.lock(); defer { lock.unlock() }
            return launches.filter { $0.arguments == ["--version"] && $0.executable.hasPrefix("/") }.count
        }

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            timeout: TimeInterval
        ) throws -> ProcessResult {
            lock.lock()
            launches.append((executable, arguments))
            lock.unlock()
            // `/usr/bin/which <cmd>` is a non-side-effecting PATH probe (no `--version` touch).
            // Return success only if the test says the command resolves; never call onTouch for it.
            if executable == "/usr/bin/which" {
                let command = arguments.first ?? ""
                if resolvableExecutables.contains(command) {
                    return ProcessResult(exitCode: 0, stdout: "/fake/\(command)\n", stderr: "")
                }
                return ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
            }
            // A bare `claude` probe only "succeeds" if the test says it resolves.
            if !executable.hasPrefix("/"), !resolvableExecutables.contains(executable) {
                return ProcessResult(exitCode: 127, stdout: "", stderr: "not found")
            }
            onTouch?()
            return ProcessResult(exitCode: 0, stdout: "1.2.3\n", stderr: "")
        }
    }

    private final class FingerprintBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ClaudeCredentialFingerprint
        init(_ value: ClaudeCredentialFingerprint) { self.value = value }
        var current: ClaudeCredentialFingerprint { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: ClaudeCredentialFingerprint) { lock.lock(); defer { lock.unlock() }; self.value = value }
    }

    private func makeCoordinator(
        processRunner: ProcessRunning,
        environment: [String: String] = [:],
        executableCLIPaths: Set<String> = [],
        fingerprint: @escaping @Sendable () -> ClaudeCredentialFingerprint,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000_000) }
    ) -> ClaudeDelegatedRefreshCoordinator {
        ClaudeDelegatedRefreshCoordinator(
            processRunner: processRunner,
            environment: FakeEnvironment(environment),
            homeDirectory: { URL(fileURLWithPath: "/Users/test") },
            currentFingerprint: fingerprint,
            now: now,
            sleep: { _ in }, // no real waiting in tests
            isExecutable: { executableCLIPaths.contains($0) },
            defaults: defaults,
            lastAttemptKey: "last",
            cooldownKey: "cooldown"
        )
    }

    func testCLIUnavailableDoesNotConsumeCooldown() async {
        // No absolute CLI candidate is executable and a bare `claude` probe fails to resolve.
        let runner = RecordingProcessRunner(resolvableExecutables: [])
        let box = FingerprintBox(.init(tokenHash: "a"))
        let coordinator = makeCoordinator(processRunner: runner, fingerprint: { box.current })

        let outcome = await coordinator.attempt()
        XCTAssertEqual(outcome, .cliUnavailable)
        // No cooldown was stamped, so the next attempt is NOT skipped by cooldown (it's cliUnavailable again).
        let second = await coordinator.attempt()
        XCTAssertEqual(second, .cliUnavailable)
        XCTAssertEqual(runner.touchCount, 0) // never reached the touch
    }

    func testSucceedsOnlyWhenFingerprintChanges() async {
        let box = FingerprintBox(.init(tokenHash: "before"))
        let cliPath = "/opt/homebrew/bin/claude"
        // The touch rotates the credential.
        let runner = RecordingProcessRunner(resolvableExecutables: []) { box.set(.init(tokenHash: "after")) }
        let coordinator = makeCoordinator(
            processRunner: runner,
            executableCLIPaths: [cliPath],
            fingerprint: { box.current }
        )

        let outcome = await coordinator.attempt()
        XCTAssertEqual(outcome, .attemptedSucceeded)
        XCTAssertEqual(runner.touchCount, 1)
        XCTAssertEqual(runner.launches.last?.executable, cliPath)
    }

    func testTouchRanButUnchangedFingerprintFails() async {
        let box = FingerprintBox(.init(tokenHash: "same"))
        let cliPath = "/opt/homebrew/bin/claude"
        // The touch runs but does NOT rotate the credential.
        let runner = RecordingProcessRunner(resolvableExecutables: [])
        let coordinator = makeCoordinator(
            processRunner: runner,
            executableCLIPaths: [cliPath],
            fingerprint: { box.current }
        )

        let outcome = await coordinator.attempt()
        guard case .attemptedFailed = outcome else {
            return XCTFail("expected attemptedFailed, got \(outcome)")
        }
        XCTAssertEqual(runner.touchCount, 1)
    }

    func testSkippedByCooldownWithinWindowThenAllowedAfter() async {
        let box = FingerprintBox(.init(tokenHash: "same"))
        let cliPath = "/opt/homebrew/bin/claude"
        let runner = RecordingProcessRunner(resolvableExecutables: [])
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let coordinator = makeCoordinator(
            processRunner: runner,
            executableCLIPaths: [cliPath],
            fingerprint: { box.current },
            now: { clock.now }
        )

        // First attempt: touch runs, unchanged → attemptedFailed, short cooldown stamped.
        _ = await coordinator.attempt()
        XCTAssertEqual(runner.touchCount, 1)

        // Within the short cooldown window: skipped, no new touch.
        clock.set(Date(timeIntervalSince1970: 1_000_000 + 5))
        let skipped = await coordinator.attempt()
        XCTAssertEqual(skipped, .skippedByCooldown)
        XCTAssertEqual(runner.touchCount, 1)

        // After the 20s short cooldown: allowed again, a second touch runs.
        clock.set(Date(timeIntervalSince1970: 1_000_000 + 21))
        _ = await coordinator.attempt()
        XCTAssertEqual(runner.touchCount, 2)
    }

    func testSuccessStampsLongerCooldown() async {
        let box = FingerprintBox(.init(tokenHash: "before"))
        let cliPath = "/opt/homebrew/bin/claude"
        let runner = RecordingProcessRunner(resolvableExecutables: []) { box.set(.init(tokenHash: "after")) }
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000))
        let coordinator = makeCoordinator(
            processRunner: runner,
            executableCLIPaths: [cliPath],
            fingerprint: { box.current },
            now: { clock.now }
        )

        let first = await coordinator.attempt()
        XCTAssertEqual(first, .attemptedSucceeded)
        // 1 minute later we should still be inside the 5-min success cooldown.
        clock.set(Date(timeIntervalSince1970: 1_000_000 + 60))
        let second = await coordinator.attempt()
        XCTAssertEqual(second, .skippedByCooldown)
        XCTAssertEqual(runner.touchCount, 1)
    }

    func testCLIPathEnvOverrideHonored() async {
        let box = FingerprintBox(.init(tokenHash: "before"))
        let overridePath = "/custom/bin/claude"
        let runner = RecordingProcessRunner(resolvableExecutables: []) { box.set(.init(tokenHash: "after")) }
        let coordinator = makeCoordinator(
            processRunner: runner,
            environment: ["CLAUDE_CLI_PATH": overridePath],
            executableCLIPaths: [overridePath],
            fingerprint: { box.current }
        )

        let outcome = await coordinator.attempt()
        XCTAssertEqual(outcome, .attemptedSucceeded)
        XCTAssertEqual(runner.launches.last?.executable, overridePath)
    }

    func testSingleFlightSharesOneLaunch() async {
        let box = FingerprintBox(.init(tokenHash: "before"))
        let cliPath = "/opt/homebrew/bin/claude"
        let runner = RecordingProcessRunner(resolvableExecutables: []) { box.set(.init(tokenHash: "after")) }
        let coordinator = makeCoordinator(
            processRunner: runner,
            executableCLIPaths: [cliPath],
            fingerprint: { box.current }
        )

        // Fire several concurrent attempts; they should share one in-flight touch.
        async let a = coordinator.attempt()
        async let b = coordinator.attempt()
        async let c = coordinator.attempt()
        let outcomes = await [a, b, c]

        XCTAssertTrue(outcomes.allSatisfy { $0 == .attemptedSucceeded })
        XCTAssertEqual(runner.touchCount, 1, "concurrent attempts must share a single CLI launch")
    }

    func testSuccessCooldownUsesInjectedTimeNotNowClosure() async {
        // Bugbot #ed400fe6: runTouchAndVerify stamped the success cooldown with now() (the closure)
        // while the short cooldown at attempt start used the `moment` passed via attempt(now:).
        // Callers that inject time only via the parameter got mismatched cooldown timestamps. Fix:
        // stamp the success cooldown with `moment` for consistency.
        let box = FingerprintBox(.init(tokenHash: "before"))
        let cliPath = "/opt/homebrew/bin/claude"
        let runner = RecordingProcessRunner(resolvableExecutables: []) { box.set(.init(tokenHash: "after")) }
        // makeCoordinator's default `now` closure returns 1_000_000; inject a DIFFERENT time via
        // attempt(now:) to expose the mismatch.
        let coordinator = makeCoordinator(
            processRunner: runner,
            executableCLIPaths: [cliPath],
            fingerprint: { box.current }
        )

        let injectedTime = Date(timeIntervalSince1970: 2_000_000)
        let outcome = await coordinator.attempt(now: injectedTime)
        XCTAssertEqual(outcome, .attemptedSucceeded)

        // The success cooldown must be stamped with the injected time (2_000_000), not the closure's
        // default time (1_000_000). Reading the persisted lastAttempt timestamp verifies which time
        // source was used.
        let stamped = defaults.double(forKey: "last")
        XCTAssertEqual(stamped, injectedTime.timeIntervalSince1970, accuracy: 0.001,
                       "success cooldown must use the injected `moment` time, not the now() closure")
    }

    func testPathBasedProbeUsesWhichNotVersion() async {
        // Bugbot #d30aea11: when the CLI is resolved only via PATH, resolveCLI() used to run
        // `claude --version` as a probe BEFORE runTouchAndVerify captured its baseline fingerprint.
        // If that probe rotated the credential, the baseline reflected the post-probe state, the
        // second touch looked unchanged, and the coordinator returned .attemptedFailed even though
        // rotation already happened. Fix: commandExists uses `/usr/bin/which` (no side effect)
        // instead of `claude --version`, so the probe doesn't rotate the credential and the touch's
        // rotation is detected against the pre-touch baseline.
        let box = FingerprintBox(.init(tokenHash: "before"))
        // `resolvableExecutables: ["claude"]` makes the `which claude` probe succeed AND the bare
        // `claude --version` touch succeed. `onTouch` rotates the credential on every non-`which`
        // launch — with the fix, only the touch (not the probe) triggers it.
        let runner = RecordingProcessRunner(resolvableExecutables: ["claude"]) { box.set(.init(tokenHash: "after")) }
        let coordinator = makeCoordinator(
            processRunner: runner,
            executableCLIPaths: [],  // no absolute path → fall back to PATH-based resolution
            fingerprint: { box.current }
        )

        let outcome = await coordinator.attempt()
        XCTAssertEqual(outcome, .attemptedSucceeded,
                       "PATH-based probe must not rotate the credential before the baseline; the touch's rotation must be detected")

        // The PATH probe should use `/usr/bin/which`, not `claude --version`.
        let whichLaunches = runner.launches.filter { $0.executable == "/usr/bin/which" }
        XCTAssertFalse(whichLaunches.isEmpty, "commandExists should use /usr/bin/which for PATH resolution")
    }
}

/// A mutable clock for coordinator tests (the provider tests have their own private `TestClock`).
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Date) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

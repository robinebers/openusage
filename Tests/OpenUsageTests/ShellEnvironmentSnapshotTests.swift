import XCTest
@testable import OpenUsage

@MainActor
final class ShellEnvironmentSnapshotTests: XCTestCase {
    func testStoreRoundtripsSnapshot() {
        let defaults = makeScratchDefaults()
        let store = ShellEnvironmentSnapshotStore(defaults: defaults)
        let snapshot = ShellEnvironmentSnapshot(
            values: ["CLAUDE_CONFIG_DIR": "~/.claude-work", "XDG_CONFIG_HOME": "~/.config"],
            capturedAt: Date(timeIntervalSince1970: 1_752_800_000)
        )

        store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
    }

    func testUndecodableSnapshotIsDiscarded() {
        let defaults = makeScratchDefaults()
        defaults.set(Data("not json".utf8), forKey: ShellEnvironmentSnapshotStore.storageKey)
        let store = ShellEnvironmentSnapshotStore(defaults: defaults)

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: ShellEnvironmentSnapshotStore.storageKey))
    }

    func testCurrentIsNilWhenCaptureFailed() {
        // An empty capture means the spawn or parse failed (a real login shell always exports
        // PATH/HOME) — its "facts" must not be persisted as a snapshot.
        let shellEnvironment = LoginShellEnvironment(runner: FixedRunner(stdout: "no markers"))
        XCTAssertFalse(shellEnvironment.ensureCapturedForTesting(), "an empty capture must report failure")
        XCTAssertNil(ShellEnvironmentSnapshot.current(shellEnvironment: shellEnvironment))
    }

    func testCurrentCapturesOnlyDeclaredKeys() {
        let stdout = [
            "__OPENUSAGE_ENV_BEGIN__",
            "CLAUDE_CONFIG_DIR=~/.claude-work",
            "OPENROUTER_API_KEY=sk-or-secret",
            "PATH=/usr/bin",
            "__OPENUSAGE_ENV_END__",
        ].joined(separator: "\0")
        let shellEnvironment = LoginShellEnvironment(runner: FixedRunner(stdout: stdout))
        XCTAssertTrue(shellEnvironment.ensureCapturedForTesting())

        let snapshot = ShellEnvironmentSnapshot.current(shellEnvironment: shellEnvironment)

        // Only the declared non-secret keys land in the snapshot — never API keys or tokens.
        XCTAssertEqual(snapshot?.values, ["CLAUDE_CONFIG_DIR": "~/.claude-work"])
    }

    func testRefreshTaskPersistsSnapshotAfterCapture() async {
        let defaults = makeScratchDefaults()
        let store = ShellEnvironmentSnapshotStore(defaults: defaults)
        let stdout = [
            "__OPENUSAGE_ENV_BEGIN__", "CODEX_HOME=/tmp/codex-home", "PATH=/usr/bin", "__OPENUSAGE_ENV_END__",
        ].joined(separator: "\0")
        let shellEnvironment = LoginShellEnvironment(runner: FixedRunner(stdout: stdout))

        await store.startRefreshTask(shellEnvironment: shellEnvironment).value

        XCTAssertEqual(store.load()?.values, ["CODEX_HOME": "/tmp/codex-home"])
    }

    func testRefreshTaskKeepsPreviousSnapshotWhenCaptureFails() async {
        let defaults = makeScratchDefaults()
        let store = ShellEnvironmentSnapshotStore(defaults: defaults)
        let previous = ShellEnvironmentSnapshot(values: ["CODEX_HOME": "/tmp/old"], capturedAt: Date())
        store.save(previous)
        let shellEnvironment = LoginShellEnvironment(runner: FixedRunner(stdout: "capture failed"))

        await store.startRefreshTask(shellEnvironment: shellEnvironment).value

        XCTAssertEqual(store.load(), previous)
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ShellEnvironmentSnapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

private final class FixedRunner: ProcessRunning, @unchecked Sendable {
    let stdout: String

    init(stdout: String) { self.stdout = stdout }

    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}

private extension LoginShellEnvironment {
    /// Force the capture from the test's (main) thread by hopping off-main, since `ensureCaptured`
    /// refuses to spawn on the main thread.
    func ensureCapturedForTesting() -> Bool {
        let done = DispatchSemaphore(value: 0)
        var result = false
        DispatchQueue.global().async {
            result = self.ensureCaptured()
            done.signal()
        }
        done.wait()
        return result
    }
}

import XCTest
import os
@testable import OpenUsage

/// The pieces under a managed Codex sign-in that touch the real system: locating the CLI, running
/// a login process (against throwaway shell scripts), and reading its output.
final class CodexLoginLauncherTests: XCTestCase {
    private static let home = URL(fileURLWithPath: "/Users/dev")

    // MARK: - Locating the CLI and reading its output

    func testExecutableSearchPathPrefersTheLoginShell() {
        let path = CodexExecutableLocator.searchPath(
            shellPATH: "/opt/homebrew/bin:~/.bun/bin", processPATH: "/usr/bin:/opt/homebrew/bin", home: Self.home
        )
        XCTAssertEqual(Array(path.prefix(3)), ["/opt/homebrew/bin", "/Users/dev/.bun/bin", "/usr/bin"])
        XCTAssertEqual(path.filter { $0 == "/opt/homebrew/bin" }.count, 1)
        XCTAssertEqual(
            CodexExecutableLocator.locate(searchPath: ["/a", "/b"], isExecutable: { $0 == "/b/codex" }),
            "/b/codex"
        )
        XCTAssertNil(CodexExecutableLocator.locate(searchPath: path, isExecutable: { _ in false }))
    }

    func testCompleteSignInURLWaitsForABoundary() {
        XCTAssertNil(CodexLoginOutput.completeSignInURL(in: "https://auth.openai.com/oauth?x=1"))
        XCTAssertEqual(CodexLoginOutput.completeSignInURL(in: "see https://auth.openai.com/oauth?x=1\n"), "https://auth.openai.com/oauth?x=1")
        XCTAssertNil(CodexLoginOutput.completeSignInURL(in: "https://auth.ope"))
    }

    func testDiagnosticLineStripsColorsAndLinks() {
        let output = "Starting local login server on http://localhost:1455.\n\u{1B}[31mError logging in: see https://example.com/help now\u{1B}[0m\n"
        XCTAssertEqual(CodexLoginOutput.diagnosticLine(in: output), "Error logging in: see <url> now")
        XCTAssertNil(CodexLoginOutput.diagnosticLine(in: "Welcome to Codex\n"))
    }

    // MARK: - Real login processes

    private func makeScript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-login-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func testRealLauncherStreamsOutputAndReportsTheExitStatus() async throws {
        let script = try makeScript("printf 'first '; sleep 0.1; printf 'second\\n'; echo \"$CODEX_HOME\" >&2; exit 3")
        let collected = OutputCollector()
        let status = try await SystemCodexLoginLauncher().runLogin(
            executable: script.path, arguments: [], environment: ["CODEX_HOME": "/managed/home", "PATH": "/usr/bin:/bin"],
            timeout: 10, onOutput: { collected.append($0) }
        )
        XCTAssertEqual(status, 3)
        XCTAssertEqual(collected.text, "first second\n/managed/home\n")
    }

    func testRealLauncherCancelKillsTheWrapperAndItsChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("codex-login-child-\(UUID().uuidString).pid")
        addTeardownBlock { try? FileManager.default.removeItem(at: pidFile) }
        let script = try makeScript("sleep 30 & echo $! > '\(pidFile.path)'; echo started; wait")
        let collected = OutputCollector()
        let task = Task {
            try await SystemCodexLoginLauncher().runLogin(
                executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                timeout: 30, onOutput: { collected.append($0) }
            )
        }
        for _ in 0..<200 where !collected.text.contains("started") { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(10)) }
        let childPID = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(isAlive(childPID))

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(isAlive(childPID), "the wrapper's child must be gone once cancellation returns")
    }

    func testRealLauncherTimeoutWaitsForAStubbornProcessToDie() async throws {
        // Ignores TERM and keeps looping even when its `sleep` children are killed, so only the
        // SIGKILL escalation ends it — the launcher must not surface the timeout before that. The
        // pid lands in a file first, so readiness can be observed independently of the deadline.
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("codex-login-stubborn-\(UUID().uuidString).pid")
        addTeardownBlock { try? FileManager.default.removeItem(at: pidFile) }
        let script = try makeScript("echo $$ > '\(pidFile.path)'; trap '' TERM; while :; do sleep 1; done")
        let collected = OutputCollector()
        let started = Date()
        let task = Task {
            try await SystemCodexLoginLauncher().runLogin(
                executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                timeout: 3, onOutput: { collected.append($0) }
            )
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(10)) }
        guard let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
            task.cancel()
            _ = try? await task.value
            throw XCTSkip("the fixture did not start within 2 s on this machine; the timeout path needs a running child to prove anything")
        }
        do {
            _ = try await task.value
            XCTFail("expected a timeout")
        } catch CodexLoginLaunchError.timedOut {}
        XCTAssertFalse(isAlive(pid), "the process must be dead, not merely signalled, when the timeout surfaces")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 3.0)
    }

    func testTheLastOutputArrivesBeforeTheOutcome() async throws {
        // The CLI's final error line is what the user sees; it must be delivered even when the
        // callback for an earlier chunk is still running — for longer than the idle-read bound —
        // as the process exits.
        let script = try makeScript("echo first; sleep 0.1; echo 'Error logging in: synthetic'; exit 1")
        let collected = OutputCollector()
        let status = try await SystemCodexLoginLauncher().runLogin(
            executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            timeout: 10, onOutput: { chunk in
                if chunk.hasPrefix("first") { Thread.sleep(forTimeInterval: 2.5) }
                collected.append(chunk)
            }
        )
        XCTAssertEqual(status, 1)
        XCTAssertTrue(collected.text.contains("Error logging in: synthetic"), collected.text)
    }

    func testALastLineAfterALongSilenceStillArrivesBeforeTheOutcome() async throws {
        // The CLI waits on the browser in silence longer than the idle-read bound, then prints its
        // error and exits: that read was not stuck, and its line must be delivered first.
        let script = try makeScript("sleep 2.5; echo 'Error logging in: final after idle'; exit 1")
        let collected = OutputCollector()
        let status = try await SystemCodexLoginLauncher().runLogin(
            executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            timeout: 10, onOutput: { collected.append($0) }
        )
        XCTAssertEqual(status, 1)
        XCTAssertTrue(collected.text.contains("Error logging in: final after idle"), collected.text)
    }

    func testTheOutcomeWaitsForAChunkStillInTheReadersHands() async throws {
        // The CLI's last line is read, then the reader parks in its callback for longer than the
        // idle bound while the group dies. Only the reader knows the line is undelivered, so the
        // launcher must wait on it rather than on any clock of its own.
        let script = try makeScript("echo 'Error logging in: parked'; exit 1")
        let gate = DispatchSemaphore(value: 0)
        let collected = OutputCollector()
        let returned = OutputCollector()
        let login = Task {
            let status = try await SystemCodexLoginLauncher().runLogin(
                executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                timeout: 10, onOutput: { chunk in
                    gate.wait()
                    collected.append(chunk)
                }
            )
            returned.append("returned")
            return status
        }
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(returned.text, "", "the launcher returned while the reader still held the last line")
        gate.signal()
        let status = try await login.value
        XCTAssertEqual(status, 1)
        XCTAssertTrue(collected.text.contains("Error logging in: parked"), collected.text)
    }

    func testADetachedWriterDoesNotHoldTheOutcomeHostage() async throws {
        // A grandchild that left the group keeps the pipe's write end: the login must still return
        // once the group is gone, after the idle-read bound, rather than waiting on that writer.
        let script = try makeScript("/usr/bin/perl -e 'use POSIX; setsid(); sleep 6' & echo \"pid $$\"; exit 0")
        let collected = OutputCollector()
        let started = Date()
        let status = try await SystemCodexLoginLauncher().runLogin(
            executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            timeout: 30, onOutput: { collected.append($0) }
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(status, 0)
        XCTAssertTrue(collected.text.contains("pid "))
        XCTAssertGreaterThan(elapsed, 2.0)
        XCTAssertLessThan(elapsed, 5.5, "must not wait for the detached writer's own exit")
    }

    func testRealLauncherCancelKillsAWrapperThatRespawnsItsChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("codex-login-respawn-\(UUID().uuidString).pids")
        addTeardownBlock { try? FileManager.default.removeItem(at: pidFile) }
        // Ignores TERM and starts a fresh child whenever the current one dies — only a whole
        // process-group kill ends this family.
        let script = try makeScript("trap '' TERM; echo \"pid $$\"; while :; do sleep 30 & echo $! >> '\(pidFile.path)'; wait $!; done")
        let collected = OutputCollector()
        let task = Task {
            try await SystemCodexLoginLauncher().runLogin(
                executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                timeout: 30, onOutput: { collected.append($0) }
            )
        }
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<300 where !collected.text.contains("pid ") { try await Task.sleep(for: .milliseconds(10)) }
        let root = try XCTUnwrap(collected.text.firstMatch(of: /pid (\d+)/).flatMap { Int32($0.1) })

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        XCTAssertFalse(isAlive(root))
        let children = try String(contentsOf: pidFile, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        XCTAssertFalse(children.isEmpty)
        XCTAssertTrue(children.allSatisfy { !isAlive($0) }, "every child, including respawned ones, must be gone: \(children)")
    }

    func testLoginEndsOnlyWhenTheWholeGroupIsGone() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("codex-login-leader-\(UUID().uuidString).pid")
        addTeardownBlock { try? FileManager.default.removeItem(at: pidFile) }
        // The wrapper honors TERM and dies; its child ignores TERM and would outlive it. Cancel must
        // not return before that child is gone either.
        let script = try makeScript("sh -c 'trap \"\" TERM; echo child $$ > \"\(pidFile.path)\"; sleep 30' & echo \"pid $$\"; wait")
        let collected = OutputCollector()
        let task = Task {
            try await SystemCodexLoginLauncher().runLogin(
                executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                timeout: 30, onOutput: { collected.append($0) }
            )
        }
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(10)) }
        let child = try XCTUnwrap(try String(contentsOf: pidFile, encoding: .utf8).firstMatch(of: /child (\d+)/).flatMap { Int32($0.1) })
        XCTAssertTrue(isAlive(child))

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(isAlive(child), "a child that outlived its wrapper must be dead before cancel returns")
    }

    func testChildStartsWithSignalsUnblockedAndAtDefaults() async throws {
        // A child that could not take SIGTERM would print the marker; an unblocked default handler ends it first.
        let script = try makeScript("kill -TERM $$; echo term-survived")
        let collected = OutputCollector()
        let status = try await SystemCodexLoginLauncher().runLogin(
            executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            timeout: 10, onOutput: { collected.append($0) }
        )
        XCTAssertEqual(status, 128 + SIGTERM)
        XCTAssertFalse(collected.text.contains("term-survived"))
    }

    func testOutputKeepsMultiByteCharactersSplitAcrossReads() async throws {
        let script = try makeScript("printf '\\316'; sleep 0.2; printf '\\262\\n'")
        let collected = OutputCollector()
        _ = try await SystemCodexLoginLauncher().runLogin(
            executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            timeout: 10, onOutput: { collected.append($0) }
        )
        XCTAssertEqual(collected.text, "β\n")
        XCTAssertEqual(CodexLoginProcess.completeUTF8PrefixLength(of: [0x61, 0xCE]), 1)
        XCTAssertEqual(CodexLoginProcess.completeUTF8PrefixLength(of: [0xCE, 0xB2]), 2)
        XCTAssertEqual(CodexLoginProcess.completeUTF8PrefixLength(of: [0xF0, 0x9F]), 0)
    }

    func testQuitStopsARunningLogin() async throws {
        // Even a root that ignores TERM must be gone when the quit hook returns.
        let script = try makeScript("trap '' TERM; echo \"pid $$\"; while :; do sleep 1; done")
        let collected = OutputCollector()
        let task = Task {
            try await SystemCodexLoginLauncher().runLogin(
                executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                timeout: 30, onOutput: { collected.append($0) }
            )
        }
        for _ in 0..<200 where !collected.text.contains("pid") { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try XCTUnwrap(collected.text.firstMatch(of: /pid (\d+)/).flatMap { Int32($0.1) })

        addTeardownBlock { CodexLoginProcesses.resumeAfterTerminateForTesting() }
        CodexLoginProcesses.terminateAll()

        let status = try await task.value
        XCTAssertNotEqual(status, 0)
        XCTAssertFalse(isAlive(pid))
    }

    func testAStopThatArrivesAfterDisarmSignalsNothing() async throws {
        // Once the group is reported gone, its id may already belong to someone else: a stop that
        // lands after that (a timeout or cancel racing the natural exit) must send no signal at all.
        let child = try CodexLoginProcess.spawn(executable: "/bin/sleep", arguments: ["30"], environment: [:])
        let drained = child.startDraining(idleSecondsAfterGroupExit: 2) { _ in }
        let stopper = GroupStopper(pgid: child.pid)
        stopper.disarm()

        stopper.stop(reason: .timedOut)
        try await Task.sleep(for: .milliseconds(1300))

        XCTAssertTrue(isAlive(child.pid), "a disarmed stopper still signalled the (possibly reused) group")
        XCTAssertNil(stopper.reason)
        kill(-child.pid, SIGKILL)
        _ = await child.waitForGroupExit(stopper: stopper)
        drained.markGroupExited()
        _ = await drained.waitUntilFinished()
    }

    func testDisarmWaitsForAStopInFlightAndCancelsItsEscalation() async throws {
        // The deadline fires as the group exits on its own: a stop already past its check must
        // finish — SIGTERM and escalation together — before disarm can run, and the disarm must then
        // cancel that escalation. Nothing may reach the group's id after disarm.
        let sent = OSAllocatedUnfairLock<[Int32]>(initialState: [])
        let inSignal = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopper = GroupStopper(pgid: 4242) { _, signal in
            sent.withLock { $0.append(signal) }
            if signal == SIGTERM {
                inSignal.signal()
                release.wait()
            }
        }
        Thread { stopper.stop(reason: .timedOut) }.start()
        XCTAssertEqual(inSignal.wait(timeout: .now() + 5), .success)
        let disarmed = DispatchSemaphore(value: 0)
        Thread { stopper.disarm(); disarmed.signal() }.start()

        XCTAssertEqual(disarmed.wait(timeout: .now() + .milliseconds(300)), .timedOut, "disarm cut in before the stop finished")
        release.signal()
        XCTAssertEqual(disarmed.wait(timeout: .now() + 5), .success)
        try await Task.sleep(for: .milliseconds(1300))

        XCTAssertEqual(sent.withLock { $0 }, [SIGTERM])
        XCTAssertEqual(stopper.reason, .timedOut)
    }

    func testDisarmWaitsForAnEscalationAlreadyMidSignal() async throws {
        // The SIGKILL escalation was dequeued just as the group exited on its own: disarm must wait
        // for it (it signals under the lock), and an escalation dequeued after disarm sends nothing.
        let sent = OSAllocatedUnfairLock<[Int32]>(initialState: [])
        let inKill = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopper = GroupStopper(pgid: 4243) { _, signal in
            sent.withLock { $0.append(signal) }
            if signal == SIGKILL {
                inKill.signal()
                release.wait()
            }
        }
        stopper.stop(reason: .timedOut)
        XCTAssertEqual(inKill.wait(timeout: .now() + 5), .success, "the escalation never fired")
        let disarmed = DispatchSemaphore(value: 0)
        Thread { stopper.disarm(); disarmed.signal() }.start()

        XCTAssertEqual(disarmed.wait(timeout: .now() + .milliseconds(300)), .timedOut, "disarm cut in during the escalation's signal")
        release.signal()
        XCTAssertEqual(disarmed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(sent.withLock { $0 }, [SIGTERM, SIGKILL])

        // An escalation dequeued before disarm but taking the lock only after it: nothing.
        release.signal() // a wrongful SIGKILL must record and return instead of parking
        stopper.escalateUnlessDisarmed()
        XCTAssertEqual(sent.withLock { $0 }, [SIGTERM, SIGKILL], "an escalation that ran after disarm still signalled")
    }

    func testAFinishedLoginLeavesNothingForAQuitToSignal() async throws {
        // Once a login's group is empty its id is free for reuse: nothing of it may stay registered
        // for a later quit to signal.
        let script = try makeScript("exit 0")
        _ = try await SystemCodexLoginLauncher().runLogin(
            executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            timeout: 10, onOutput: { _ in }
        )
        XCTAssertEqual(CodexLoginProcesses.registeredGroupCountForTesting, 0, "a finished login left its group id for a quit")
    }

    func testALoginThatEndedIsNotTimedOutByADeadlineDuringTheDrain() async throws {
        // The group is gone, but the reader is still delivering the last output when the deadline
        // passes: the login ended on its own, so its status stands and its stopper stays quiet.
        let script = try makeScript("echo 'Successfully logged in'; exit 0")
        let status = try await SystemCodexLoginLauncher().runLogin(
            executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            timeout: 1.5, onOutput: { _ in Thread.sleep(forTimeInterval: 3) }
        )
        XCTAssertEqual(status, 0)
    }

    func testALoginCannotStartOnceTheAppIsQuitting() async throws {
        // A spawn racing the quit hook would leave a process nobody stops: once the hook ran, a
        // login that has not started yet is refused and its executable never runs.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("codex-login-ran-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
        let script = try makeScript("touch '\(marker.path)'")
        addTeardownBlock { CodexLoginProcesses.resumeAfterTerminateForTesting() }
        CodexLoginProcesses.terminateAll()

        do {
            _ = try await SystemCodexLoginLauncher().runLogin(
                executable: script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                timeout: 10, onOutput: { _ in }
            )
            XCTFail("a login started while the app was quitting")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
        func append(_ chunk: String) { lock.lock(); buffer += chunk; lock.unlock() }
    }
}

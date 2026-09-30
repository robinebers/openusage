import Darwin
import Foundation
import XCTest
@testable import OpenUsage

final class ProcessRunnerTests: XCTestCase {
    /// Regression: a child whose output exceeds the ~64KB OS pipe buffer must not deadlock. Before the
    /// pipes were drained concurrently, this blocked the child on write, so it never exited and tripped
    /// the timeout. (`ps -ax -o command=` — used by language-server discovery — is ~240KB.)
    func testLargeStdoutDoesNotDeadlock() throws {
        let runner = SystemProcessRunner()
        let result = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes 0123456789 | head -c 200000"],
            environment: [:],
            timeout: 10
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.count, 200_000)
    }

    func testCapturesStdoutAndExitCode() throws {
        let runner = SystemProcessRunner()
        let result = try runner.run(executable: "/bin/echo", arguments: ["hello"], environment: [:], timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    /// Queue ownership is checked directly rather than depending on a machine's worker-pool size.
    func testEveryPipeGetsItsOwnPrivateDrainQueue() {
        let queues = [true, false, true, false].map { SystemProcessRunner.makeDrainQueue(isStdout: $0) }
        let utilityPool = DispatchQueue.global(qos: .utility)
        for (index, queue) in queues.enumerated() {
            XCTAssertFalse(queue === utilityPool, "A drain must not use the shared utility pool")
            for other in queues.dropFirst(index + 1) {
                XCTAssertFalse(queue === other, "Each pipe, including across runs, needs its own queue")
            }
        }
    }

    /// Re-run only this test in a fresh process. A broken drain can otherwise hang in drained.wait()
    /// even after the command's own timeout; the outer watchdog must not use SystemProcessRunner.
    func testOutputAndTimeoutInIsolatedProcess() throws {
        let modeKey = "OPENUSAGE_PROCESS_RUNNER_FIXTURE"
        if let directory = ProcessInfo.processInfo.environment[modeKey] {
            // Give only this fixture and its synthetic descendants a killable process group.
            guard getpgrp() == getpid() || setpgid(0, 0) == 0 else {
                XCTFail("Could not isolate the process fixture: errno \(errno)")
                return
            }
            try checkOutputAndTimeout()
            try Data("completed".utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("completed"))
            return
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("fixture.log")
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest",
            "OpenUsageTests.ProcessRunnerTests/testOutputAndTimeoutInIsolatedProcess",
            Bundle(for: ProcessRunnerTests.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[modeKey] = directory.path
        // A configuration inherited from Xcode must not override our exact one-test selection.
        environment.removeValue(forKey: "XCTestConfigurationFilePath")
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        try process.run()

        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut {
            let pid = process.processIdentifier
            // Never signal the test suite's group if the fixture failed before setpgid().
            if getpgid(pid) == pid { kill(-pid, SIGKILL) }
            kill(pid, SIGKILL)
        }
        process.waitUntilExit()
        let diagnostic = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(timedOut, "ProcessRunner fixture exceeded 30s:\n\(diagnostic)")
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed").path),
            "The selected fixture did not complete:\n\(diagnostic)"
        )
    }

    private func checkOutputAndTimeout() throws {
        let runner = SystemProcessRunner()
        // Keep stdout open while writing more than a pipe buffer to stderr first. A shared serial
        // drain queue blocks waiting for stdout EOF and cannot start the stderr read.
        let result = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "/usr/bin/yes e | /usr/bin/head -c 200000 >&2; /usr/bin/yes o | /usr/bin/head -c 200000; exit 7"],
            environment: [:],
            timeout: 5
        )
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, String(repeating: "o\n", count: 100_000))
        XCTAssertEqual(result.stderr, String(repeating: "e\n", count: 100_000))

        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try runner.run(
            executable: "/bin/sleep", arguments: ["5"], environment: [:], timeout: 0.1
        )) { error in
            XCTAssertEqual(error as? ProcessRunnerError, .timedOut(executable: "/bin/sleep", timeout: 0.1))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3, "Timeout cleanup should return promptly")
    }
}

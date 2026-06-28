import XCTest
@testable import OpenUsage

final class LoginShellEnvironmentTests: XCTestCase {
    private let begin = "__OPENUSAGE_ENV_BEGIN__"
    private let end = "__OPENUSAGE_ENV_END__"

    func testParsesKeysBetweenMarkers() {
        let output = [begin, "OPENROUTER_API_KEY=sk-or-v1-abc", "PATH=/usr/bin:/bin", end]
            .joined(separator: "\0")
        let parsed = LoginShellEnvironment.parse(output)
        XCTAssertEqual(parsed["OPENROUTER_API_KEY"], "sk-or-v1-abc")
        XCTAssertEqual(parsed["PATH"], "/usr/bin:/bin")
    }

    func testIgnoresBannerOutsideMarkers() {
        // A login shell can print an MOTD/banner before our command runs; it must not be parsed.
        let output = ["Welcome to your shell!", "MOTD=should-be-ignored\0" + begin,
                      "REAL=value", end, "trailing-noise"].joined(separator: "\0")
        let parsed = LoginShellEnvironment.parse(output)
        XCTAssertEqual(parsed["REAL"], "value")
        XCTAssertNil(parsed["MOTD"])
    }

    func testKeepsValuesContainingEquals() {
        let output = [begin, "TOKEN=a=b=c", end].joined(separator: "\0")
        XCTAssertEqual(LoginShellEnvironment.parse(output)["TOKEN"], "a=b=c")
    }

    func testMissingMarkersYieldEmpty() {
        XCTAssertTrue(LoginShellEnvironment.parse("PATH=/usr/bin\0HOME=/Users/x").isEmpty)
    }

    func testResolvesKeyOffMainThread() {
        let runner = RecordingRunner(stdout: [begin, "OPENROUTER_API_KEY=sk-or-test", end].joined(separator: "\0"))
        let env = LoginShellEnvironment(runner: runner)
        let captured = expectation(description: "captured off-main")
        var value: String?
        DispatchQueue.global().async {
            value = env.value(for: "OPENROUTER_API_KEY")
            captured.fulfill()
        }
        wait(for: [captured], timeout: 5)
        XCTAssertEqual(value, "sk-or-test")
        XCTAssertEqual(runner.callCount, 1)
    }

    /// The Bugbot fix: a main-thread read before the cache is warm must not spawn or wait on the
    /// subprocess, so the UI can't freeze. It returns nil until the prewarm fills the cache.
    func testMainThreadReadDoesNotRunSubprocess() {
        let runner = RecordingRunner(stdout: [begin, "K=v", end].joined(separator: "\0"))
        let env = LoginShellEnvironment(runner: runner)
        XCTAssertNil(env.value(for: "K"))
        XCTAssertEqual(runner.callCount, 0)
    }
}

/// Returns a fixed stdout and counts how many times it was invoked, so tests can assert the capture
/// ran exactly once (or not at all on the main thread).
private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    let stdout: String
    private let lock = NSLock()
    private var count = 0

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(stdout: String) { self.stdout = stdout }

    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        lock.lock(); count += 1; lock.unlock()
        return ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}

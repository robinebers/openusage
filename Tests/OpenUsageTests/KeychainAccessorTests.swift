import XCTest
@testable import OpenUsage

final class KeychainAccessorTests: XCTestCase {
    /// Returns a fixed `ProcessResult` for any invocation — lets us drive the accessor's exit-code
    /// handling without a real `security` subprocess.
    private struct StubRunner: ProcessRunning {
        let result: ProcessResult
        func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
            result
        }
    }

    func testItemNotFoundExitReturnsNil() throws {
        // Exit 44 (errSecItemNotFound) is the legitimate "no credential stored" case → nil.
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 44, stdout: "", stderr: "The specified item could not be found in the keychain.")
        ))
        XCTAssertNil(try accessor.readGenericPassword(service: "Test"))
    }

    func testNonItemNotFoundFailureThrowsReadFailed() {
        // A non-44 non-zero exit (locked keychain / access denied / cancelled unlock) must throw, not
        // collapse into the same nil as "no credential" — otherwise it gets mislabeled "not signed in".
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 51, stdout: "", stderr: "User interaction is not allowed.")
        ))
        XCTAssertThrowsError(try accessor.readGenericPassword(service: "Test")) { error in
            guard case KeychainError.readFailed = error else {
                return XCTFail("expected KeychainError.readFailed, got \(error)")
            }
        }
    }

    func testFoundValueIsReturnedTrimmed() throws {
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 0, stdout: "secret-token\n", stderr: "")
        ))
        XCTAssertEqual(try accessor.readGenericPassword(service: "Test"), "secret-token")
    }

    func testExplicitAccountReadAndWriteUseTheSameItem() throws {
        let runner = RecordingRunner()
        let accessor: any KeychainAccessing = SecurityKeychainAccessor(processRunner: runner)
        let account = "cli|0123456789abcdef"

        _ = try accessor.readGenericPassword(service: "Codex Auth", account: account)
        try accessor.writeGenericPassword(service: "Codex Auth", account: account, value: "synthetic-token")

        XCTAssertEqual(runner.arguments, [
            ["find-generic-password", "-a", account, "-s", "Codex Auth", "-w"],
            ["add-generic-password", "-U", "-a", account, "-s", "Codex Auth", "-w", "synthetic-token"]
        ])
    }

    func testExplicitAccountWriteFailurePropagates() {
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 51, stdout: "", stderr: "User interaction is not allowed.")
        ))
        XCTAssertThrowsError(try accessor.writeGenericPassword(
            service: "Codex Auth", account: "cli|0123456789abcdef", value: "synthetic-token"
        )) { error in
            guard case KeychainError.writeFailed = error else {
                return XCTFail("expected KeychainError.writeFailed, got \(error)")
            }
        }
    }

    func testUnsupportedAccountWriteDoesNotFallBackToServiceOnly() {
        let keychain = FakeKeychain("original")
        XCTAssertThrowsError(try keychain.writeGenericPassword(
            service: "Codex Auth", account: "cli|0123456789abcdef", value: "replacement"
        ))
        XCTAssertEqual(keychain.value, "original")
    }

    private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
        var arguments: [[String]] = []

        func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
            XCTAssertEqual(executable, "/usr/bin/security")
            self.arguments.append(arguments)
            return ProcessResult(exitCode: 0, stdout: "synthetic-token", stderr: "")
        }
    }
}

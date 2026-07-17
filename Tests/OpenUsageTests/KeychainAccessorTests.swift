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

    private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
        var timeouts: [TimeInterval] = []

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            timeout: TimeInterval
        ) throws -> ProcessResult {
            timeouts.append(timeout)
            return ProcessResult(exitCode: 44, stdout: "", stderr: "not found")
        }
    }

    private struct ThrowingRunner: ProcessRunning {
        struct ProbeFailure: Error {}

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            timeout: TimeInterval
        ) throws -> ProcessResult {
            throw ProbeFailure()
        }
    }

    func testAttributeProbeUsesItsShortLaunchPathTimeout() {
        let runner = RecordingRunner()
        let accessor = SecurityKeychainAccessor(processRunner: runner, attributeProbeTimeout: 0.05)

        XCTAssertFalse(accessor.hasGenericPassword(service: "Test", account: "account"))
        XCTAssertEqual(runner.timeouts, [0.05])
    }

    func testAttributeProbeFailureIsConservativelyTreatedAsPossibleFootprint() {
        let timedOut = SecurityKeychainAccessor(
            processRunner: ThrowingRunner(),
            attributeProbeTimeout: 0.05
        )
        let denied = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 51, stdout: "", stderr: "interaction not allowed")
        ))

        XCTAssertTrue(timedOut.hasGenericPassword(service: "Test", account: "account"))
        XCTAssertTrue(denied.hasGenericPassword(service: "Test", account: "account"))
        XCTAssertFalse(SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 44, stdout: "", stderr: "not found")
        )).hasGenericPassword(service: "Test", account: "account"))
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

    func testAttributeFingerprintIsOpaqueStableAndVersionSensitive() throws {
        let first = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(
                exitCode: 0,
                stdout: "",
                stderr: """
                keychain: "/Users/alice/Library/Keychains/login.keychain-db"
                attributes:
                    "acct"<blob>="cli|abc"
                    "mdat"<timedate>=0x32303236303731373132303030305A00
                """
            )
        ))
        let same = first.genericPasswordAttributeFingerprint(service: "Codex Auth", account: "cli|abc")
        let changed = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(
                exitCode: 0,
                stdout: "",
                stderr: """
                keychain: "/Users/alice/Library/Keychains/login.keychain-db"
                attributes:
                    "acct"<blob>="cli|abc"
                    "mdat"<timedate>=0x32303236303731373132303030315A00
                """
            )
        )).genericPasswordAttributeFingerprint(service: "Codex Auth", account: "cli|abc")

        XCTAssertEqual(same?.count, 64)
        XCTAssertEqual(
            same,
            first.genericPasswordAttributeFingerprint(service: "Codex Auth", account: "cli|abc")
        )
        XCTAssertNotEqual(same, changed)
        XCTAssertFalse(try XCTUnwrap(same).contains("alice"))
    }
}

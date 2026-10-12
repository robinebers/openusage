import Security
import XCTest
@testable import OpenUsage

final class SecurityToolItemAccessorTests: XCTestCase {
    func testReadWaitsForThePopupInsteadOfClosingIt() {
        let runner = RecordingProcessRunner(ProcessResult(exitCode: 0, stdout: "token\n", stderr: ""))
        let accessor = SecurityToolItemAccessor(processRunner: runner)

        let result = accessor.readGenericPasswordData(service: "Claude Code-credentials", account: "me")

        XCTAssertEqual(result.status, errSecSuccess)
        XCTAssertEqual(result.data, Data("token\n".utf8))
        XCTAssertEqual(runner.calls.first?.arguments, ["find-generic-password", "-a", "me", "-s", "Claude Code-credentials", "-w"])
        XCTAssertGreaterThanOrEqual(
            runner.calls.first?.timeout ?? 0, 5 * 60,
            "ending security early closes the popup before Always Allow is saved"
        )
    }

    func testSaveUpdatesTheLoginInPlace() {
        let runner = RecordingProcessRunner(ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let accessor = SecurityToolItemAccessor(processRunner: runner)

        let status = accessor.updateGenericPasswordData(service: "cursor-access-token", account: "cursor-user", data: Data("new".utf8))

        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(runner.calls.first?.arguments, ["add-generic-password", "-U", "-a", "cursor-user", "-s", "cursor-access-token", "-w", "new"])
    }

    func testSavingANewLoginWithoutAnAccountStillPassesOne() {
        let runner = RecordingProcessRunner(ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let accessor = SecurityToolItemAccessor(processRunner: runner)

        _ = accessor.addGenericPasswordData(service: "cursor-access-token", account: nil, data: Data("new".utf8))
        _ = accessor.readGenericPasswordData(service: "cursor-access-token", account: nil)

        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [
                ["add-generic-password", "-U", "-a", "", "-s", "cursor-access-token", "-w", "new"],
                ["find-generic-password", "-s", "cursor-access-token", "-w"],
            ],
            "security refuses to save without -a, while a read without one finds the login under any account"
        )
    }

    func testExitCodesMapToKeychainStatuses() {
        let cases: [(exitCode: Int32, status: OSStatus)] = [
            (44, errSecItemNotFound),
            (51, errSecAuthFailed),
            (128, errSecUserCanceled),
            (36, errSecInteractionNotAllowed),
            (1, errSecInternalComponent),
        ]
        for (exitCode, status) in cases {
            let runner = RecordingProcessRunner(ProcessResult(exitCode: exitCode, stdout: "", stderr: ""))

            let result = SecurityToolItemAccessor(processRunner: runner).readGenericPasswordData(service: "gemini", account: nil)

            XCTAssertEqual(result.status, status, "exit \(exitCode)")
            XCTAssertNil(result.data)
        }
    }

    private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
        let result: ProcessResult
        var calls: [(arguments: [String], timeout: TimeInterval)] = []

        init(_ result: ProcessResult) {
            self.result = result
        }

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            timeout: TimeInterval
        ) throws -> ProcessResult {
            XCTAssertEqual(executable, "/usr/bin/security")
            calls.append((arguments, timeout))
            return result
        }
    }
}

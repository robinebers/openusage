import XCTest
@testable import OpenUsage

/// Covers the shared response triage and authenticated retry sequence used across providers, including
/// the cancellation signals that must not be rewritten as provider connection failures.
@MainActor
final class ProviderAuthRetryTests: XCTestCase {
    private enum SampleError: Error, Equatable {
        case authExpired
        case connectionFailed
        case retriedConnectionFailed
        case requestFailed(Int)
    }

    private func requireSuccess(status: Int) throws {
        let response = HTTPResponse(statusCode: status, headers: [:], body: Data())
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: SampleError.authExpired,
            requestFailed: { SampleError.requestFailed($0) }
        )
    }

    func testSuccessStatusesDoNotThrow() throws {
        for status in [200, 201, 204, 299] {
            try requireSuccess(status: status)
        }
    }

    func testUnauthorizedAndForbiddenThrowAuthExpired() {
        for status in [401, 403] {
            XCTAssertThrowsError(try requireSuccess(status: status)) { error in
                XCTAssertEqual(error as? SampleError, .authExpired)
            }
        }
    }

    func testOtherNon2xxThrowRequestFailedWithStatus() {
        for status in [400, 404, 429, 500, 503] {
            XCTAssertThrowsError(try requireSuccess(status: status)) { error in
                XCTAssertEqual(error as? SampleError, .requestFailed(status))
            }
        }
    }

    func testInitialAttemptPreservesCancellationErrors() async {
        await assertCancellationPreserved(CancellationError(), throwingOnAttempt: 1)
        await assertCancellationPreserved(URLError(.cancelled), throwingOnAttempt: 1)
    }

    func testRetriedAttemptPreservesCancellationErrors() async {
        await assertCancellationPreserved(CancellationError(), throwingOnAttempt: 2)
        await assertCancellationPreserved(URLError(.cancelled), throwingOnAttempt: 2)
    }

    private func assertCancellationPreserved(
        _ expectedError: Error,
        throwingOnAttempt targetAttempt: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var attemptCount = 0
        do {
            _ = try await ProviderAuthRetry.fetch(
                token: "old-token",
                attempt: { _ in
                    attemptCount += 1
                    if attemptCount == targetAttempt {
                        throw expectedError
                    }
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                },
                refreshAccessToken: { "new-token" },
                connectionFailed: SampleError.connectionFailed,
                retriedConnectionFailed: SampleError.retriedConnectionFailed,
                authExpired: SampleError.authExpired
            )
            XCTFail("Expected cancellation from attempt \(targetAttempt)", file: file, line: line)
        } catch is CancellationError {
            XCTAssertTrue(expectedError is CancellationError, file: file, line: line)
        } catch let error as URLError {
            XCTAssertEqual((expectedError as? URLError)?.code, .cancelled, file: file, line: line)
            XCTAssertEqual(error.code, .cancelled, file: file, line: line)
        } catch {
            XCTFail("Expected the original cancellation, got \(error)", file: file, line: line)
        }
    }
}

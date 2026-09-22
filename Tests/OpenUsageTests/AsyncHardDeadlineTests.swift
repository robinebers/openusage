import XCTest
import os
@testable import OpenUsage

final class AsyncHardDeadlineTests: XCTestCase {
    func testCompletedInsideDeadlineReturnsValue() async throws {
        let outcome = try await AsyncHardDeadline.run(timeout: 1) {
            "ok"
        }
        guard case .completed(let value) = outcome else {
            return XCTFail("expected completed, got \(outcome)")
        }
        XCTAssertEqual(value, "ok")
    }

    func testTimeoutCancelsHungWork() async throws {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let outcome = try await AsyncHardDeadline.run(timeout: 0.05) {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch is CancellationError {
                cancelled.withLock { $0 = true }
                throw CancellationError()
            }
            return "late"
        }
        guard case .timedOut = outcome else {
            return XCTFail("expected timedOut, got \(outcome)")
        }
        let sawCancel = await waitUntil { cancelled.withLock { $0 } }
        XCTAssertTrue(sawCancel)
    }

    func testOperationErrorPropagatesInsideDeadline() async {
        struct Boom: Error {}
        do {
            _ = try await AsyncHardDeadline.run(timeout: 1) {
                throw Boom()
            }
            XCTFail("expected Boom")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}

import XCTest
@testable import OpenUsage

@MainActor
final class CodexHistoryRefreshTests: XCTestCase {
    func testSlowScanDoesNotBlockOrRestartAndCompletedResultIsCollected() async {
        let refresh = CodexHistoryRefresh<Int>()
        var continuation: CheckedContinuation<Int, Never>?
        var starts = 0
        let operation: @MainActor () async -> Int = {
            starts += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        let first = await refresh.value(wait: .zero, operation: operation)
        XCTAssertNil(first)
        while continuation == nil { await Task.yield() }
        let second = await refresh.value(wait: .zero, operation: operation)
        XCTAssertNil(second)
        XCTAssertEqual(starts, 1)
        continuation?.resume(returning: 42)
        let completed = await refresh.value(wait: .seconds(1), operation: operation)
        XCTAssertEqual(completed, 42)
        XCTAssertEqual(starts, 1)
        let next = await refresh.value(wait: .seconds(1)) { 43 }
        XCTAssertEqual(next, 43)
    }

    func testCancelledWaitDoesNotDiscardInFlightScan() async {
        let refresh = CodexHistoryRefresh<Int>()
        var release: CheckedContinuation<Int, Never>?
        let waiter = Task { await refresh.value(wait: .seconds(30)) {
            await withCheckedContinuation { release = $0 }
        } }
        while release == nil { await Task.yield() }
        waiter.cancel()
        let cancelled = await waiter.value
        XCTAssertNil(cancelled)
        release?.resume(returning: 9)
        let recovered = await refresh.value(wait: .seconds(1)) { XCTFail("Duplicate scan"); return 0 }
        XCTAssertEqual(recovered, 9)
    }

    func testPositiveBudgetReturnsWithoutWaitingForNonCooperativeScan() async {
        let refresh = CodexHistoryRefresh<Int>()
        var release: CheckedContinuation<Int, Never>?
        let clock = ContinuousClock()
        let start = clock.now
        let value = await refresh.value(wait: .milliseconds(20)) {
            await withCheckedContinuation { release = $0 }
        }
        XCTAssertNil(value)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        release?.resume(returning: 4)
        let completed = await refresh.value(wait: .seconds(1)) { XCTFail("Duplicate scan"); return 0 }
        XCTAssertEqual(completed, 4)
    }

    func testReleasingOwnerCancelsBackgroundWork() async {
        var refresh: CodexHistoryRefresh<Int>? = CodexHistoryRefresh()
        weak var weakRefresh = refresh
        let started = expectation(description: "started")
        let cancelled = expectation(description: "cancelled")
        _ = await refresh?.value(wait: .zero) {
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled.fulfill() }
            return 1
        }
        await fulfillment(of: [started], timeout: 1)
        refresh = nil
        XCTAssertNil(weakRefresh)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testFastScanIsIncludedInSameRefresh() async {
        let refresh = CodexHistoryRefresh<Int>()
        let value = await refresh.value(wait: .seconds(1)) { 7 }
        XCTAssertEqual(value, 7)
    }
}

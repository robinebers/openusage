import Observation
import XCTest
@testable import OpenUsage

@MainActor
final class TransientNoticeTests: XCTestCase {
    func testCopyingAgainRestartsTheConfirmation() async throws {
        let timeout = Duration.milliseconds(80)
        let notice = TransientNotice(clearedValue: false, timeout: timeout)
        notice.present(true)
        try await Task.sleep(for: .milliseconds(40))

        let copiedAgain = ContinuousClock.now
        notice.present(true)
        XCTAssertTrue(notice.value)
        XCTAssertEqual(notice.trigger, 2)

        let dismissed = expectation(description: "the confirmation clears after the second copy")
        withObservationTracking {
            _ = notice.value
        } onChange: {
            XCTAssertGreaterThanOrEqual(copiedAgain.duration(to: ContinuousClock.now), timeout)
            dismissed.fulfill()
        }
        await fulfillment(of: [dismissed], timeout: 2)
        XCTAssertFalse(notice.value)
    }

    func testClosingDismissesTheConfirmationImmediately() {
        let popover = PopoverState()
        popover.shareNotice.present(true)
        popover.reset()
        XCTAssertFalse(popover.shareNotice.value)
    }
}

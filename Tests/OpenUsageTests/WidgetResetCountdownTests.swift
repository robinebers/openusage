import Foundation
import XCTest
import OpenUsageWidgetSupport

final class WidgetResetCountdownTests: XCTestCase {
    private let resetAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testFutureResetUsesAnIntervalEndingAtTheDeadline() {
        let entryDate = resetAt.addingTimeInterval(-300)
        XCTAssertEqual(WidgetResetCountdown(resetAt: resetAt, at: entryDate), .remaining(entryDate...resetAt))
    }

    func testAtAndAfterResetUseStaticDueState() {
        for elapsed: TimeInterval in [0, 300, 86_400] {
            let countdown = WidgetResetCountdown(resetAt: resetAt, at: resetAt.addingTimeInterval(elapsed))
            XCTAssertEqual(countdown, .due)
            XCTAssertEqual(countdown.widthTemplate, "soon")
        }
    }

    func testWidthReservesAllTimerDigitsIncludingRoundedHourBoundaries() {
        let cases: [(TimeInterval, String)] = [
            (300, "88:88"), (3_599, "88:88"), (3_599.5, "8:88:88"),
            (3_600, "8:88:88"), (36_000, "88:88:88"), (360_000, "888:88:88")
        ]
        for (remaining, template) in cases {
            XCTAssertEqual(
                WidgetResetCountdown(resetAt: resetAt, at: resetAt.addingTimeInterval(-remaining)).widthTemplate,
                template
            )
        }
    }
}

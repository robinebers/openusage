import Foundation
import XCTest
import OpenUsageWidgetSupport

final class WidgetCountdownFormatStyleTests: XCTestCase {
    private let resetAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let styles: [WidgetCountdownFormatStyle.Style] = [.relative, .leadingUnit, .minutes]

    func testEveryCountdownStopsAtTheDeadlineAndStaysDueAfterward() {
        for style in styles {
            let format = WidgetCountdownFormatStyle(resetAt: resetAt, style: style)
            XCTAssertNotEqual(format.format(resetAt.addingTimeInterval(-300)), "soon")
            XCTAssertEqual(format.format(resetAt), "soon")
            XCTAssertEqual(format.format(resetAt.addingTimeInterval(300)), "soon")
            XCTAssertEqual(format.format(resetAt.addingTimeInterval(86_400)), "soon")
        }
    }

    func testLiveTextSchedulesTheDeadlineWithoutAnotherTimelineOrHostRefresh() {
        let lastInstant = Date(timeIntervalSinceReferenceDate: resetAt.timeIntervalSinceReferenceDate.nextDown)
        for style in styles {
            let format = WidgetCountdownFormatStyle(resetAt: resetAt, style: style)
            XCTAssertEqual(format.discreteInput(after: lastInstant), resetAt)
            XCTAssertEqual(format.discreteInput(before: resetAt), lastInstant)
            XCTAssertNil(format.discreteInput(after: resetAt))
            XCTAssertNil(format.discreteInput(after: resetAt.addingTimeInterval(300)))
        }
    }

    func testScheduledLiveUpdatesActuallyChangeTheDisplayedText() throws {
        for style in styles {
            let format = WidgetCountdownFormatStyle(resetAt: resetAt, style: style)
            for remaining: TimeInterval in [61, 300, 3_599, 3_600, 86_401] {
                let before = resetAt.addingTimeInterval(-remaining)
                let next = try XCTUnwrap(format.discreteInput(after: before))
                XCTAssertGreaterThan(next, before)
                XCTAssertLessThanOrEqual(next, resetAt)
                XCTAssertNotEqual(format.format(next), format.format(before), "\(style), \(remaining)")
            }
        }
    }
}

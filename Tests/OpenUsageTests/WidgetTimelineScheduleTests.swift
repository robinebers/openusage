import XCTest
import OpenUsageWidgetSupport

final class WidgetTimelineScheduleTests: XCTestCase {
    func testEntriesStayEvenlySpacedPastTheRequestedReload() {
        // WidgetKit can postpone the reload, so countdown layouts rely on entries already in the timeline.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dates = WidgetTimelineSchedule.entryDates(from: now)

        XCTAssertEqual(dates.first, now)
        XCTAssertEqual(dates.last, now.addingTimeInterval(WidgetTimelineSchedule.horizon))
        XCTAssertEqual(dates.count, 9)
        for (earlier, later) in zip(dates, dates.dropFirst()) {
            XCTAssertEqual(later.timeIntervalSince(earlier), WidgetTimelineSchedule.entrySpacing)
        }
    }
}

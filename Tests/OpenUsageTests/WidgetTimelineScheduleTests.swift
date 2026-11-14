import XCTest
import OpenUsageWidgetSupport

final class WidgetTimelineScheduleTests: XCTestCase {
    func testResetDeadlinesWithinTheHorizonAreIncludedOnce() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = now.addingTimeInterval(10)
        let end = now.addingTimeInterval(WidgetTimelineSchedule.horizon)
        let dates = WidgetTimelineSchedule.entryDates(from: now, resetDates: [
            now.addingTimeInterval(-1), now, deadline, deadline,
            now.addingTimeInterval(WidgetTimelineSchedule.entrySpacing), end, end.addingTimeInterval(1)
        ])

        XCTAssertEqual(dates, (WidgetTimelineSchedule.entryDates(from: now) + [deadline]).sorted())
        XCTAssertEqual(WidgetResetCountdown(resetAt: deadline, at: dates[1]), .due)
    }

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

import XCTest
@testable import OpenUsage

/// Covers the relative/absolute reset display: the shared `Formatters.deadlineLabel` (one helper for
/// every "<verb> + when" string), its absolute day buckets (ported from the original
/// `formatResetAbsoluteLabel`), and `WidgetData` honoring the global mode for the trailing label,
/// the opposite-format tooltip, and the "Limit in …" run-out projection.
final class ResetDisplayTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testAbsoluteLabelDayBuckets() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12))! // noon, stable

        XCTAssertTrue(Formatters.resetAbsoluteLabel(at: now.addingTimeInterval(2 * 3600),
                                                    now: now, calendar: calendar)!.hasPrefix("Resets today at "))

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!.addingTimeInterval(3600)
        XCTAssertTrue(Formatters.resetAbsoluteLabel(at: tomorrow,
                                                    now: now, calendar: calendar)!.hasPrefix("Resets tomorrow at "))

        let later = calendar.date(byAdding: .day, value: 5, to: now)!
        let label = Formatters.resetAbsoluteLabel(at: later, now: now, calendar: calendar)!
        XCTAssertTrue(label.hasPrefix("Resets ") && label.contains(" at "))
        XCTAssertFalse(label.hasPrefix("Resets today"))
        XCTAssertFalse(label.hasPrefix("Resets tomorrow"))

        XCTAssertEqual(Formatters.resetAbsoluteLabel(at: now.addingTimeInterval(-1),
                                                     now: now, calendar: calendar), "Resets soon")
    }

    func testWidgetDataTrailingAndTooltipHonorMode() {
        var data = WidgetData(title: "Weekly", icon: .symbol("clock"),
                              kind: .percent, used: 50, limit: 100)
        data.resetsAt = Date().addingTimeInterval(4 * 24 * 3600 + 17 * 3600) // ~4d17h out
        data.periodDurationMs = 7 * 24 * 60 * 60 * 1000
        XCTAssertTrue(data.hasResetLabel)

        data.resetDisplayMode = .relative
        XCTAssertEqual(data.boundedTrailingText?.hasPrefix("Resets in "), true)
        XCTAssertEqual(data.resetTooltip?.hasPrefix("Resets "), true)         // opposite = absolute

        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.boundedTrailingText?.hasPrefix("Resets "), true)
        XCTAssertEqual(data.resetTooltip?.hasPrefix("Resets in "), true)      // opposite = relative
    }

    func testExpiryTooltipSingleCreditFollowsTimeSetting() {
        // One reset credit: the row reads "1 available" and the hover tooltip is a single line. Relative
        // → "Reset expires in 12d 18h"; absolute → a wall-clock phrase ("Reset expires … at …").
        var data = WidgetData(title: "Rate Limit Resets", icon: .symbol("clock"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 1, kind: .count, label: "available")]
        data.expiriesAt = [Date().addingTimeInterval(12 * 24 * 3600 + 18 * 3600)] // ~12d18h out

        XCTAssertEqual(data.unboundedDetail, "1 available")

        data.resetDisplayMode = .relative
        XCTAssertEqual(data.expiryTooltip, "Reset expires in 12d 18h")

        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.expiryTooltip?.hasPrefix("Reset expires "), true)
        XCTAssertEqual(data.expiryTooltip?.contains(" at "), true)        // wall-clock, not "in"
    }

    func testExpiryTooltipMultipleCreditsIsNumberedList() {
        // Several credits: the tooltip is a numbered list under a header, sorted soonest-first, each
        // entry following the global mode. The row itself still reads just the count.
        var data = WidgetData(title: "Rate Limit Resets", icon: .symbol("clock"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 2, kind: .count, label: "available")]
        data.expiriesAt = [
            Date().addingTimeInterval(12 * 24 * 3600 + 18 * 3600), // ~12d18h
            Date().addingTimeInterval(22 * 24 * 3600 + 12 * 3600)  // ~22d12h
        ]
        data.resetDisplayMode = .relative

        XCTAssertEqual(data.unboundedDetail, "2 available")
        XCTAssertEqual(data.expiryTooltip, "Resets expire in:\n1. 12d 18h\n2. 22d 12h")
    }

    func testHasImminentExpiryTracksWarningWindow() {
        // The warning triangle fires when the soonest credit expires within `expiryWarningWindow`.
        // Anchored to the constant so it survives the eventual 21d→24h revert.
        var data = WidgetData(title: "Rate Limit Resets", icon: .symbol("clock"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 2, kind: .count, label: "available")]

        // Soonest just inside the window → warning (even though a later credit is well outside it).
        data.expiriesAt = [
            Date().addingTimeInterval(WidgetData.expiryWarningWindow - 3600),
            Date().addingTimeInterval(WidgetData.expiryWarningWindow + 10 * 24 * 3600)
        ]
        XCTAssertTrue(data.hasImminentExpiry)

        // Every credit comfortably outside the window → no warning.
        data.expiriesAt = [Date().addingTimeInterval(WidgetData.expiryWarningWindow + 24 * 3600)]
        XCTAssertFalse(data.hasImminentExpiry)

        // No expiries at all → no warning.
        data.expiriesAt = []
        XCTAssertFalse(data.hasImminentExpiry)
    }

    func testNoExpiryTooltipWhenNoExpiries() {
        // The empty state — "0 available" — and any row without expiries carry no expiry tooltip.
        var data = WidgetData(title: "Rate Limit Resets", icon: .symbol("clock"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 0, kind: .count, label: "available")]
        XCTAssertEqual(data.unboundedDetail, "0 available")
        XCTAssertNil(data.expiryTooltip)
    }

    func testDeadlineLabelSharesFormatAcrossPrefixesAndModes() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12))!

        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(2 * 3600 + 360),
                                                mode: .relative, now: now), "Runs out in 2h 6m")
        XCTAssertTrue(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(2 * 3600),
                                               mode: .absolute, now: now, calendar: calendar)!
            .hasPrefix("Runs out today at "))
        // Imminent deadlines collapse to "soon" in both modes, same as the reset label.
        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(60),
                                                mode: .relative, now: now), "Runs out soon")
        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(-1),
                                                mode: .absolute, now: now, calendar: calendar), "Runs out soon")
    }

    /// The `runningOut` run-out time, present only when the bar is red and projects to run out
    /// before the reset. Evaluated against the real clock (default `now`) to match the resetsAt set
    /// from `Date()` below.
    private func runningOutEta(_ data: WidgetData) -> String? {
        if case .runningOut(let eta, _) = data.meterState() { return eta }
        return nil
    }

    func testRunningOutEtaHonorsResetDisplayMode() {
        // Halfway through a 10h window with 90/100 used → behind pace, projected run-out ~34m away,
        // safely before the reset 5h out. The label carries its own "Limit" verb (no flame in tests),
        // so the copy reads "Limit in 34m" / "Limit today at …".
        var data = WidgetData(title: "Session", icon: .symbol("clock"),
                              kind: .percent, used: 90, limit: 100)
        data.resetsAt = Date().addingTimeInterval(5 * 3600)
        data.periodDurationMs = 10 * 3600 * 1000

        data.resetDisplayMode = .relative
        XCTAssertEqual(runningOutEta(data)?.hasPrefix("Limit in "), true) // e.g. "Limit in 34m"
        XCTAssertEqual(runningOutEta(data)?.hasSuffix("m"), true)         // compact duration like "34m"

        data.resetDisplayMode = .absolute
        // Wall-clock reading ~34m out: "Limit today at …", or "Limit tomorrow at …" when the test runs
        // near local midnight (`WidgetData` evaluates against the real clock, so the bucket can roll).
        let absolute = runningOutEta(data)
        XCTAssertEqual(absolute?.hasPrefix("Limit today at ") == true
                        || absolute?.hasPrefix("Limit tomorrow at ") == true, true)
    }

    func testNoResetLabelWithoutResetDate() {
        var data = WidgetData(title: "Credits", icon: .symbol("creditcard"),
                              kind: .dollars, used: 12, limit: 20)
        data.resetDisplayMode = .absolute
        XCTAssertFalse(data.hasResetLabel)          // no resetsAt → not a clickable reset
        XCTAssertNil(data.resetTooltip)
        XCTAssertEqual(data.boundedTrailingText, "$20 limit") // falls back to limit context, unflipped
    }
}

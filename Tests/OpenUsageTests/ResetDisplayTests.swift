import XCTest
@testable import OpenUsage

/// Covers the relative/absolute reset display: `Formatters.whenLabel` (the claim timeline's and claim
/// notice's "when" phrase) with its absolute day buckets, the session rows' "not started" state (an
/// empty reset column), the reset-credit expiry bands, and the resets popover's entries.
final class ResetDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testWhenLabelBucketsTheDayAndCollapsesImminentDeadlines() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12))! // noon, stable

        XCTAssertEqual(Formatters.whenLabel(at: now.addingTimeInterval(2 * 3600 + 360), mode: .relative, now: now), "2h 6m")
        XCTAssertTrue(Formatters.whenLabel(at: now.addingTimeInterval(2 * 3600),
                                           mode: .absolute, now: now, calendar: calendar)!.hasPrefix("today at "))

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!.addingTimeInterval(3600)
        XCTAssertTrue(Formatters.whenLabel(at: tomorrow,
                                           mode: .absolute, now: now, calendar: calendar)!.hasPrefix("tomorrow at "))

        let later = calendar.date(byAdding: .day, value: 5, to: now)!
        let label = Formatters.whenLabel(at: later, mode: .absolute, now: now, calendar: calendar)!
        XCTAssertTrue(label.contains(" at "))
        XCTAssertFalse(label.hasPrefix("today") || label.hasPrefix("tomorrow"))

        // Imminent deadlines collapse to "soon" in both modes.
        XCTAssertEqual(Formatters.whenLabel(at: now.addingTimeInterval(60), mode: .relative, now: now), "soon")
        XCTAssertEqual(Formatters.whenLabel(at: now.addingTimeInterval(-1),
                                            mode: .absolute, now: now, calendar: calendar), "soon")
    }

    func testFreshSessionWindowReadsNotStartedAndSuppressesPacing() {
        let period: TimeInterval = 5 * 3600
        var data = WidgetData(title: "Session", kind: .percent, used: 0, limit: 100)
        data.sessionStartSignal = .zeroUsage
        data.periodDurationMs = Int(period * 1000)
        data.resetsAt = now.addingTimeInterval(period / 2)

        XCTAssertTrue(data.isFreshSessionWindow(now: now))
        XCTAssertEqual(data.dashboardRow(now: now).mark, .bar(fill: 0, severity: .normal, value: "0%", reset: nil))
        XCTAssertEqual(data.meterState(now: now), .level(.normal))

        // Once the reset has passed the snapshot is stale: no "not started" claim, the normal countdown.
        XCTAssertFalse(data.isFreshSessionWindow(now: data.resetsAt!.addingTimeInterval(1)))
    }

    func testMissingResetDateSignalKeepsCountdownForSubOnePercentSession() {
        // Claude reports utilization in whole percents, so an in-flight session under 1% reads
        // used == 0 — but its reset date exists precisely because the window started. The row must show
        // the normal countdown, never "not started".
        var data = WidgetData(title: "Session", kind: .percent, used: 0, limit: 100)
        data.sessionStartSignal = .missingResetDate
        data.periodDurationMs = 5 * 3600 * 1000
        data.resetsAt = now.addingTimeInterval(2 * 3600)

        XCTAssertFalse(data.isFreshSessionWindow(now: now))
        XCTAssertEqual(data.compactResetText(now: now), "2h")

        // A genuinely fresh session carries no reset date — that is this signal's "not started" state.
        data.resetsAt = nil
        XCTAssertTrue(data.isFreshSessionWindow(now: now))
        XCTAssertNil(data.compactResetText(now: now))
    }

    func testNonSessionWindowNeverReadsNotStarted() {
        let period: TimeInterval = 7 * 24 * 3600
        var data = WidgetData(title: "Weekly", kind: .percent, used: 0, limit: 100)
        data.periodDurationMs = Int(period * 1000)
        data.resetsAt = now.addingTimeInterval(period / 2)

        XCTAssertFalse(data.isFreshSessionWindow(now: now))
        XCTAssertEqual(data.compactResetText(now: now), "3d 12h")
    }

    func testTheResetFollowsTheClockSetting() {
        // Halfway through a 10h window with 90/100 used: a red bar, the flame (projected to run out
        // ~34m out, well before the reset 5h out), and the reset in the clock form under that setting.
        var data = WidgetData(title: "Session", kind: .percent, used: 90, limit: 100)
        data.resetsAt = now.addingTimeInterval(5 * 3600)
        data.periodDurationMs = 10 * 3600 * 1000

        data.resetDisplayMode = .relative
        XCTAssertEqual(data.dashboardRow(now: now).mark, .bar(fill: 0.9, severity: .critical, value: "90%", reset: "5h", flame: true))

        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.compactResetText(now: now), Formatters.compactClock(data.resetsAt!, now: now))
    }

    func testACapWithoutAResetDateHasNoResetUnderEitherClockSetting() {
        var data = WidgetData(title: "Credits", kind: .dollars, used: 12, limit: 20)
        for mode in [ResetDisplayMode.relative, .absolute] {
            data.resetDisplayMode = mode
            XCTAssertNil(data.compactResetText(now: now))
        }
    }

    func testExpirySeverityBands() {
        // A reset credit's dot: red under 48 hours, orange under 7 days, blue beyond.
        XCTAssertEqual(WidgetData.expirySeverity(secondsRemaining: WidgetData.expiryCriticalWindow - 3600), .critical)
        XCTAssertEqual(WidgetData.expirySeverity(secondsRemaining: -60), .critical)
        XCTAssertEqual(WidgetData.expirySeverity(secondsRemaining: WidgetData.expiryCriticalWindow + 3600), .warning)
        XCTAssertEqual(WidgetData.expirySeverity(secondsRemaining: WidgetData.expiryWarningWindow + 24 * 3600), .normal)
    }

    @MainActor
    func testResetsRowIsWiredOnlyOnClaudeAndCodexAccounts() {
        let runtimes = ProviderKind.allCases.map {
            AccountProviderRuntime(account: Account(kind: $0, label: "Work"), vault: InMemoryCredentialVault())
        }
        let resetsRows = runtimes.flatMap { runtime in
            runtime.widgetDescriptors.filter { $0.sample.showsResetExpiries || $0.sample.traySuffix != nil }
        }

        XCTAssertEqual(resetsRows.map(\.id), runtimes.filter { [.claude, .codex].contains($0.account.kind) }
            .map { "\($0.account.cardID).rateLimitResets" })
        for row in resetsRows {
            XCTAssertEqual(row.sample.title, "Limit Resets")
            XCTAssertEqual(row.metricLabel, "Rate Limit Resets")
            XCTAssertEqual(row.sample.traySuffix, "resets")
            XCTAssertTrue(row.sample.showsResetExpiries)
        }
    }

    func testResetsPopoverEntriesAreSoonestFirstAndNumbered() {
        // The popover timeline sorts the resets soonest-first, numbers them from 1, and pairs each exact
        // expiry time with its countdown. Per-reset dot color reuses the expiry severity bands.
        let entries = RateLimitResetsDetail.entries(
            from: [
                // Deliberately out of order to prove the sort.
                now.addingTimeInterval(12 * 24 * 3600 + 18 * 3600),          // ~12d18h -> blue
                now.addingTimeInterval(WidgetData.expiryCriticalWindow - 3600) // <48h  -> red, soonest
            ],
            now: now
        )

        XCTAssertEqual(entries.map(\.number), [1, 2])
        XCTAssertEqual(entries[0].severity, .critical)   // soonest sorts first
        XCTAssertEqual(entries[1].severity, .normal)
        XCTAssertEqual(entries[1].time.contains(" at "), true) // exact wall-clock time leads
        XCTAssertEqual(entries[1].countdown, "12d 18h")        // countdown trails
    }

    func testResetsPopoverPastDueAndImminentEntriesReadSoonWithNoCountdown() {
        for offset in [-60.0, 180.0] {
            let entries = RateLimitResetsDetail.entries(from: [now.addingTimeInterval(offset)], now: now)

            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries[0].time, "Expiring soon")
            XCTAssertNil(entries[0].countdown)
            XCTAssertEqual(entries[0].severity, .critical)
        }
    }

    func testResetsPopoverEmptyWhenNoResets() {
        XCTAssertTrue(RateLimitResetsDetail.entries(from: [], now: now).isEmpty)
    }

    func testResetsPopoverContentResolvesEmptyCountOnlyAndTimeline() {
        // Zero resets -> the genuine empty state.
        XCTAssertEqual(RateLimitResetsDetail.content(count: 0, expiries: [], now: now), .empty)

        // Resets present but no expiry list (the dedicated fetch failed, so the row fell back to the
        // usage-body count): must NOT read "no resets"; it states the count instead.
        XCTAssertEqual(
            RateLimitResetsDetail.content(count: 3, expiries: [], now: now),
            .unknownExpiries(count: 3)
        )

        // Expiries present -> the timeline.
        let expiries = [now.addingTimeInterval(4 * 24 * 3600)]
        guard case .timeline(let entries) = RateLimitResetsDetail.content(count: 1, expiries: expiries, now: now) else {
            return XCTFail("expected timeline")
        }
        XCTAssertEqual(entries.count, 1)
    }

    func testCompactDurationAlwaysShowsHoursAtDayScale() {
        // Day-scale durations always show two units so a whole-day-ish span never reads as a flat "Xd"
        // that hides the sub-day remainder. Sub-day durations are unchanged.
        XCTAssertEqual(Formatters.compactDuration(4 * 24 * 3600 + 52 * 60), "4d 0h") // 4d 52m -> "4d 0h"
        XCTAssertEqual(Formatters.compactDuration(7 * 24 * 3600), "7d 0h")            // exact week
        XCTAssertEqual(Formatters.compactDuration(9 * 24 * 3600 + 21 * 3600), "9d 21h")
        XCTAssertEqual(Formatters.compactDuration(5 * 3600), "5h")                    // sub-day unchanged
        XCTAssertEqual(Formatters.compactDuration(52 * 60), "52m")
    }
}

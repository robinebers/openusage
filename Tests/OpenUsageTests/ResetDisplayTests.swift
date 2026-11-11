import XCTest
@testable import OpenUsage

final class ResetDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testWhenLabelBucketsTheDayAndCollapsesImminentDeadlines() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12))!

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
        XCTAssertEqual(data.meterState(now: now), .unpaced)

        XCTAssertFalse(data.isFreshSessionWindow(now: data.resetsAt!.addingTimeInterval(1)))
    }

    func testAntigravitySessionJustUnderFullKeepsItsCountdownBehindTheRoundedPercent() {
        let line = AntigravityUsageMapper.line(
            pool: AntigravityMetric.sessionLabel, fraction: 0.99965,
            resetTime: now.addingTimeInterval(2 * 3600), periodMs: MetricPeriod.sessionMs)
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodMs) = line else {
            return XCTFail("expected a progress line")
        }
        XCTAssertEqual(used, 0.035, accuracy: 0.001)
        XCTAssertGreaterThan(used, 0)

        var data = WidgetData(title: "Gemini 5h", kind: .percent, used: used, limit: limit,
                              resetsAt: resetsAt, periodDurationMs: periodMs)
        data.sessionStartSignal = .zeroUsage
        data.displayMode = .remaining

        XCTAssertEqual(data.valueText, "100%")
        XCTAssertFalse(data.isFreshSessionWindow(now: now))
        XCTAssertEqual(data.compactResetText(now: now), "2h")
        guard case .bar(_, _, let value, let reset, _) = data.dashboardRow(now: now).mark else {
            return XCTFail("expected a bar mark")
        }
        XCTAssertEqual(value, "100%")
        XCTAssertEqual(reset, "2h")
    }

    func testAntigravityUntouchedAndExhaustedWindowsKeepTheirFreshAndCountdownReads() {
        func line(fraction: Double) -> WidgetData {
            guard case .progress(_, let used, let limit, _, let resetsAt, let periodMs) =
                    AntigravityUsageMapper.line(pool: AntigravityMetric.sessionLabel, fraction: fraction,
                                                resetTime: now.addingTimeInterval(2 * 3600),
                                                periodMs: MetricPeriod.sessionMs)
            else { preconditionFailure("expected a progress line") }
            var data = WidgetData(title: "Gemini 5h", kind: .percent, used: used, limit: limit,
                                  resetsAt: resetsAt, periodDurationMs: periodMs)
            data.sessionStartSignal = .zeroUsage
            data.displayMode = .remaining
            return data
        }

        let untouched = line(fraction: 1)
        XCTAssertTrue(untouched.isFreshSessionWindow(now: now))
        XCTAssertNil(untouched.compactResetText(now: now))

        let exhausted = line(fraction: 0)
        XCTAssertFalse(exhausted.isFreshSessionWindow(now: now))
        XCTAssertEqual(exhausted.compactResetText(now: now), "2h")

        for (fraction, expected) in [(1.5, 0.0), (-0.5, 100.0)] {
            guard case .progress(_, let used, _, _, _, _) =
                    AntigravityUsageMapper.line(pool: "x", fraction: fraction, resetTime: nil, periodMs: MetricPeriod.sessionMs)
            else { return XCTFail("expected a progress line") }
            XCTAssertEqual(used, expected, "fraction \(fraction) clamps into 0...1")
        }
    }

    func testAntigravityWeeklyKeepsTheFractionsRawPercentForTheCardToRound() {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodMs) =
                AntigravityUsageMapper.line(pool: AntigravityMetric.weeklyLabel, fraction: 0.9742,
                                            resetTime: now.addingTimeInterval(5 * 24 * 3600),
                                            periodMs: MetricPeriod.weekMs)
        else { return XCTFail("expected a progress line") }
        var data = WidgetData(title: "Gemini", kind: .percent, used: used, limit: limit,
                              resetsAt: resetsAt, periodDurationMs: periodMs)
        data.displayMode = .remaining

        XCTAssertEqual(data.valueText, "97%")
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

    func testALimitResettingMonthsOutCountsDownInMonthsAndDays() {
        var data = WidgetData(title: "Monthly", kind: .percent, used: 10, limit: 100)
        data.resetsAt = Calendar.current.date(byAdding: .month, value: 2, to: now)

        XCTAssertEqual(data.compactResetText(now: now), "2m 0d")
    }

    func testACapWithoutAResetDateHasNoResetUnderEitherClockSetting() {
        var data = WidgetData(title: "Credits", kind: .dollars, used: 12, limit: 20)
        for mode in [ResetDisplayMode.relative, .absolute] {
            data.resetDisplayMode = mode
            XCTAssertNil(data.compactResetText(now: now))
        }
    }

    @MainActor
    func testResetsRowIsWiredOnlyOnClaudeCodexAndZAIAccounts() {
        let runtimes = ProviderKind.allCases.map {
            AccountProviderRuntime(account: Account(kind: $0, label: "Work"), vault: InMemoryCredentialVault())
        }
        let resetsRows = runtimes.flatMap { runtime in
            runtime.widgetDescriptors.filter { $0.sample.showsResetExpiries }
        }

        XCTAssertEqual(resetsRows.map(\.id), runtimes.filter { [.claude, .codex, .zai].contains($0.account.kind) }
            .map { "\($0.account.cardID).rateLimitResets" })
        XCTAssertTrue(resetsRows.allSatisfy { $0.metricLabel == "Rate Limit Resets" })
    }

    func testResetsPopoverEntriesAreSoonestFirstAndNumbered() {
        let entries = RateLimitResetsDetail.entries(
            from: [
                (now.addingTimeInterval(12 * 24 * 3600 + 18 * 3600), nil),
                (now.addingTimeInterval(WidgetData.expiryCriticalWindow - 3600), nil)
            ],
            now: now
        )

        XCTAssertEqual(entries.map(\.number), [1, 2])
        XCTAssertEqual(entries[0].severity, .critical)
        XCTAssertEqual(entries[1].severity, .normal)
        XCTAssertEqual(entries[1].expiry, Formatters.whenLabel(at: entries[1].date, mode: .absolute, now: now))
        XCTAssertTrue(entries[1].expiry.contains(" at "), entries[1].expiry)
        XCTAssertEqual(entries[1].countdown, "12d 18h")
    }

    func testResetsPopoverRowReadsItsKindCountdownAndExpiryWithoutUseBy() {
        let expiry = now.addingTimeInterval(3 * 24 * 3600)
        let item = ResetItem(kind: .weekly, expiresAt: expiry, claim: .claudeGrant("g"))
        let entry = RateLimitResetsDetail.content(count: 1, expiries: [], items: [item], now: now).entries.first
        let absolute = Formatters.whenLabel(at: expiry, mode: .absolute, now: now)!
        XCTAssertEqual(entry?.item?.kind.title, "Weekly Reset")
        XCTAssertEqual(entry?.expiry, absolute)
        XCTAssertEqual(entry?.countdown, "3d 0h")
        XCTAssertEqual(entry?.accessibilityLabel, "Reset 1, Weekly Reset, \(absolute), expires in 3d 0h")
    }

    func testResetsPopoverPastDueAndImminentEntriesKeepTheirTimeAndReadExpiring() {
        for offset in [-60.0, 180.0] {
            let expiry = now.addingTimeInterval(offset)
            let entries = RateLimitResetsDetail.entries(from: [(expiry, nil)], now: now)
            let time = Formatters.dateAndTime(expiry)

            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries[0].expiry, time)
            XCTAssertNil(entries[0].countdown)
            XCTAssertEqual(entries[0].accessibilityLabel, "Reset 1, \(time), expiring")
            XCTAssertEqual(entries[0].severity, .critical)
        }
    }

    func testResetsPopoverContentResolvesEmptyCountOnlyAndTimeline() {
        XCTAssertEqual(RateLimitResetsDetail.content(count: 0, expiries: [], items: [], now: now), .empty)

        XCTAssertEqual(
            RateLimitResetsDetail.content(count: 3, expiries: [], items: [], now: now),
            .unknownExpiries(count: 3)
        )

        let expiries = [now.addingTimeInterval(4 * 24 * 3600)]
        guard case .timeline(let entries) = RateLimitResetsDetail.content(count: 1, expiries: expiries, items: [], now: now) else {
            return XCTFail("expected timeline")
        }
        XCTAssertEqual(entries.count, 1)
    }

    func testClaimingOneOfTwoResetsWithOneExpiryLeavesTheOtherOnTheTimeline() {
        let shared = now.addingTimeInterval(4 * 24 * 3600)
        let later = now.addingTimeInterval(6 * 24 * 3600)
        let items = [shared, shared, later].map { ResetItem(kind: .full, expiresAt: $0, claim: .codexCredit($0)) }

        let visible = RateLimitResetsDetail.visibleItems(items, claimed: [.codexCredit(shared): 1])
        XCTAssertEqual(visible.map(\.expiresAt), [shared, later])
        XCTAssertEqual(RateLimitResetsDetail.visibleItems(Array(items.prefix(2)), claimed: [.codexCredit(shared): 2]), [])

        let content = RateLimitResetsDetail.content(count: 3, expiries: [], items: items, claimed: [.codexCredit(shared): 1], now: now)
        XCTAssertEqual(content.entries.map(\.key), [
            .init(claim: .codexCredit(shared), date: shared, ordinal: 0), .init(claim: .codexCredit(later), date: later, ordinal: 0)
        ])
    }

    func testCountdownShowsCalendarMonthsAndDaysFromAMonthOut() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dubai")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!
        func countdown(_ components: DateComponents) -> String? {
            Formatters.countdown(to: calendar.date(byAdding: components, to: start)!, now: start, calendar: calendar)
        }
        XCTAssertEqual(countdown(DateComponents(day: 29, hour: 23)), "29d 23h", "just under a month keeps days and hours")
        XCTAssertEqual(countdown(DateComponents(month: 1)), "1m 0d", "a calendar month, Nov 10 to Dec 10, not 30 days")
        XCTAssertEqual(countdown(DateComponents(day: 30)), "1m 0d")
        XCTAssertEqual(countdown(DateComponents(month: 3, day: 27, hour: 2)), "3m 27d")
        XCTAssertEqual(countdown(DateComponents(year: 1, month: 2, day: 5)), "14m 5d")
        XCTAssertEqual(countdown(DateComponents(hour: 2, minute: 6)), "2h 6m")
        XCTAssertNil(Formatters.countdown(to: start.addingTimeInterval(-60), now: start, calendar: calendar))
        XCTAssertEqual(Formatters.whenLabel(at: calendar.date(byAdding: .month, value: 4, to: start)!, mode: .relative,
                                            now: start, calendar: calendar), "4m 0d", "the resets popover's countdown")
    }

    func testCompactDurationAlwaysShowsHoursAtDayScale() {
        XCTAssertEqual(Formatters.compactDuration(4 * 24 * 3600 + 52 * 60), "4d 0h")
        XCTAssertEqual(Formatters.compactDuration(9 * 24 * 3600 + 21 * 3600), "9d 21h")
        XCTAssertEqual(Formatters.compactDuration(5 * 3600), "5h")
        XCTAssertEqual(Formatters.compactDuration(52 * 60), "52m")
    }

    func testWeekdayTimeShowsMinutesSoTheHourNeverReadsAsADate() {
        let reset = Date(timeIntervalSince1970: 1_794_382_293) // Wed 2026-11-11 07:31:33 UTC
        let madrid = TimeZone(identifier: "Europe/Madrid")!

        XCTAssertEqual(TimeFormatSetting.auto.weekdayTime(reset, base: Locale(identifier: "es_ES"), timeZone: madrid), "mié, 8:31")
        XCTAssertEqual(TimeFormatSetting.auto.weekdayTime(reset, base: Locale(identifier: "en_US"), timeZone: madrid), "Wed 8:31\u{202F}AM")
        XCTAssertEqual(TimeFormatSetting.twentyFourHour.weekdayTime(reset, base: Locale(identifier: "en_US"), timeZone: madrid), "Wed 08:31")
    }

    func testCompactDurationOfAResetTooFarOffForAnIntShowsTheLongestCountdown() {
        XCTAssertEqual(Formatters.compactDuration(1e300), "6405119470038038d 18h")
    }
}

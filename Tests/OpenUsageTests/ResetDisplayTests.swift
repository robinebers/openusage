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
        var data = WidgetData(title: "Weekly", icon: .providerMark("codex"),
                              kind: .percent, used: 50, limit: 100)
        data.resetsAt = Date().addingTimeInterval(4 * 24 * 3600 + 17 * 3600) // ~4d17h out
        data.periodDurationMs = 7 * 24 * 60 * 60 * 1000
        XCTAssertTrue(data.hasResetLabel())

        data.resetDisplayMode = .relative
        XCTAssertEqual(data.boundedTrailingText()?.hasPrefix("Resets in "), true)
        XCTAssertEqual(data.resetTooltip()?.hasPrefix("Resets "), true)         // opposite = absolute

        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.boundedTrailingText()?.hasPrefix("Resets "), true)
        XCTAssertEqual(data.resetTooltip()?.hasPrefix("Resets in "), true)      // opposite = relative
    }

    func testFreshSessionWindowShowsNotStartedForClaudeAndAntigravity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let period: TimeInterval = 5 * 3600
        for id in ["claude.session",
                   "antigravity.geminiPro", "antigravity.claude"] {
            var data = WidgetData(title: "Session", icon: .providerMark("codex"), kind: .percent, used: 0, limit: 100)
            data.isSessionWindow = true   // descriptor opt-in the session tiles now carry
            data.periodDurationMs = Int(period * 1000)
            // Half the window has elapsed on the clock, so pace would otherwise project — but usage is
            // still zero, which is what "Not started" keys off (see `isFreshSessionWindow`).
            data.resetsAt = now.addingTimeInterval(period / 2)
            XCTAssertEqual(data.boundedTrailingText(now: now), "Not started", id)
            XCTAssertFalse(data.hasResetLabel(now: now), id)
            XCTAssertEqual(data.resetTooltip(now: now), WidgetData.freshSessionTooltip, id)
            // The bar and its hover must not contradict "Not started": a calm level state, no pace
            // projection and no tick — even with pacing forced on and the window well past minimumElapsed.
            data.alwaysShowPacing = true
            let state = data.meterState(now: now)
            XCTAssertEqual(state, .level(.normal), id)
            XCTAssertNil(state.tooltip, id)
            XCTAssertNil(data.paceTick(for: state, now: now), id)
        }
    }

    @MainActor
    func testSessionWindowFlagIsWiredOnExactlyTheShippingSessionDescriptors() {
        // The test above hand-sets `isSessionWindow`, so it pins the mechanism but not the wiring.
        // This one pins the wiring: the descriptor opt-in replaced a model-level widget-ID set, so a
        // provider dropping (or spuriously gaining) the flag must fail here, not ship silently.
        let providers: [ProviderRuntime] = [
            ClaudeProvider(), CodexProvider(), CursorProvider(),
            AntigravityProvider(), CopilotProvider(), DevinProvider(),
            GrokProvider(), OpenRouterProvider(), ZAIProvider()
        ]
        let descriptors = providers.flatMap(\.widgetDescriptors)
        let sessionIDs = Set(descriptors.filter(\.sample.isSessionWindow).map(\.id))
        XCTAssertEqual(sessionIDs, ["claude.session",
                                    "antigravity.geminiPro", "antigravity.claude"])

        // Same wiring pin for the menu-bar tray suffix (it replaced a title-string match).
        let suffixed = descriptors.filter { $0.sample.traySuffix != nil }
        XCTAssertEqual(suffixed.map(\.id), ["codex.rateLimitResets"])
        XCTAssertEqual(suffixed.first?.sample.traySuffix, "resets")
    }

    func testAntigravityWeeklyRowsNeverReadNotStarted() {
        // Antigravity's weekly meters are calendar windows, not rolling sessions — like Claude,
        // only the 5h rows get the "Not started" treatment (fix: merged pools + weekly limits).
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let period: TimeInterval = 7 * 24 * 3600
        for id in ["antigravity.geminiWeekly", "antigravity.claudeWeekly"] {
            var data = WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: 0, limit: 100)
            data.periodDurationMs = Int(period * 1000)
            data.resetsAt = now.addingTimeInterval(period / 2)
            XCTAssertFalse(data.isFreshSessionWindow(now: now), id)
            XCTAssertNotEqual(data.boundedTrailingText(now: now), "Not started", id)
            XCTAssertEqual(data.boundedTrailingText(now: now)?.hasPrefix("Resets"), true, id)
        }
    }

    func testExpiryTooltipSingleCreditFollowsTimeSetting() {
        // One reset credit: the row reads "1 available" and the hover tooltip is a single line. Relative
        // → "Reset expires in 12d 18h"; absolute → a wall-clock phrase ("Reset expires … at …").
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
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
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
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

    func testExpirySeverityTracksSoonestExpiry() {
        // The reset-credit dot reflects the soonest expiry: blue normally, yellow under 7 days, red under
        // 48 hours.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 2, kind: .count, label: "available")]

        // Soonest under 48 hours -> red, even though a later credit is well outside it.
        data.expiriesAt = [
            now.addingTimeInterval(WidgetData.expiryCriticalWindow - 3600),
            now.addingTimeInterval(WidgetData.expiryWarningWindow + 10 * 24 * 3600)
        ]
        XCTAssertEqual(data.expirySeverity(now: now), .critical)

        // Under 7 days but outside 48 hours -> yellow.
        data.expiriesAt = [now.addingTimeInterval(WidgetData.expiryCriticalWindow + 3600)]
        XCTAssertEqual(data.expirySeverity(now: now), .warning)

        // Every credit comfortably outside the warning window -> blue.
        data.expiriesAt = [now.addingTimeInterval(WidgetData.expiryWarningWindow + 24 * 3600)]
        XCTAssertEqual(data.expirySeverity(now: now), .normal)

        // No expiries at all -> no dot.
        data.expiriesAt = []
        XCTAssertNil(data.expirySeverity(now: now))
    }

    func testNoExpiryTooltipWhenNoExpiries() {
        // The empty state — "0 available" — and any row without expiries carry no expiry tooltip.
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 0, kind: .count, label: "available")]
        XCTAssertEqual(data.unboundedDetail, "0 available")
        XCTAssertNil(data.expiryTooltip)
    }

    func testResetsPopoverEntriesAreSoonestFirstAndNumbered() {
        // The popover timeline sorts the credits soonest-first, numbers them from 1, and pairs each
        // exact expiry time with its countdown. Per-credit dot color reuses the row's severity bands.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
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

    func testResetsPopoverPastDueEntryReadsSoonWithNoCountdown() {
        // A past-due credit (still "available" until the next refresh drops it) can't print a useful
        // wall-clock time or countdown, so it collapses to "Expiring soon" with no trailing countdown —
        // matching Formatters.imminent. Its dot stays red.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = RateLimitResetsDetail.entries(from: [now.addingTimeInterval(-60)], now: now)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].time, "Expiring soon")
        XCTAssertNil(entries[0].countdown)
        XCTAssertEqual(entries[0].severity, .critical)
    }

    func testResetsPopoverImminentFutureCreditCollapsesToSoon() {
        // A credit ≤5 minutes out (but not yet past-due): relative mode already reads "soon", so the
        // exact time must not print a wall-clock while the countdown vanishes — both collapse to
        // "Expiring soon" with no countdown.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = RateLimitResetsDetail.entries(from: [now.addingTimeInterval(180)], now: now)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].time, "Expiring soon")
        XCTAssertNil(entries[0].countdown)
    }

    func testResetsPopoverEmptyWhenNoCredits() {
        XCTAssertTrue(RateLimitResetsDetail.entries(from: [], now: Date()).isEmpty)
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

    func testResetsPopoverContentResolvesEmptyCountOnlyAndTimeline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // Zero credits -> the genuine empty state.
        XCTAssertEqual(RateLimitResetsDetail.content(count: 0, expiries: [], now: now), .empty)

        // Credits present but no expiry list (dedicated fetch unavailable -> usage-body count fallback):
        // must NOT read "no resets"; it states the count instead.
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
        var data = WidgetData(title: "Session", icon: .providerMark("codex"),
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
        var data = WidgetData(title: "Credits", icon: .providerMark("codex"),
                              kind: .dollars, used: 12, limit: 20)
        data.resetDisplayMode = .absolute
        XCTAssertFalse(data.hasResetLabel())        // no resetsAt → not a clickable reset
        XCTAssertNil(data.resetTooltip())
        XCTAssertEqual(data.boundedTrailingText(), "$20 limit") // falls back to limit context, unflipped
    }
}

import XCTest
@testable import OpenUsage

extension WidgetDataStoreTests {
    func testRemainingProgressWithoutResetUsesPeriodDurationLabel() {
        let session = WidgetData(
            title: "Session",
            icon: .providerMark("claude"),
            kind: .percent,
            used: 0,
            limit: 100,
            displayMode: .remaining,
            resetsAt: nil,
            periodDurationMs: ClaudeUsageMapper.sessionPeriodMs
        )
        XCTAssertEqual(session.boundedSubtitle, "Resets in 5h")

        let weekly = WidgetData(
            title: "Weekly",
            icon: .providerMark("claude"),
            kind: .percent,
            used: 0,
            limit: 100,
            displayMode: .remaining,
            resetsAt: nil,
            periodDurationMs: ClaudeUsageMapper.weeklyPeriodMs
        )
        XCTAssertEqual(weekly.boundedSubtitle, "Resets in 7d 0h")
    }

    func testDollarLimitSubtitleIsNotAReset() {
        // A dollar limit subtitle is not a reset countdown; it renders as plain "$<limit> limit" text.
        let onDemand = WidgetData(
            title: "On-demand", icon: .providerMark("cursor"),
            kind: .dollars, used: 0, limit: 100, limitNoun: "limit"
        )
        XCTAssertEqual(onDemand.boundedSubtitle, "$100 limit")
    }

    func testDonutFractionMatchesRoundedHeadline() {
        // 0.39% used reads "0%", so the ring must be empty (no sliver), not 0.0039.
        let nearlyZero = WidgetData(
            title: "Total usage",
            icon: .providerMark("cursor"),
            kind: .percent,
            used: 0.3915,
            limit: 100
        )
        XCTAssertEqual(nearlyZero.valueText, "0%")
        XCTAssertEqual(nearlyZero.fraction, 0, accuracy: 0.0001)

        // 0.6% rounds up to "1%", so the ring should match that 1%.
        let roundsUp = WidgetData(
            title: "Total usage",
            icon: .providerMark("cursor"),
            kind: .percent,
            used: 0.6,
            limit: 100
        )
        XCTAssertEqual(roundsUp.valueText, "1%")
        XCTAssertEqual(roundsUp.fraction, 0.01, accuracy: 0.0001)

        // 99.6% used reads "100%", so the ring should be full.
        let nearlyFull = WidgetData(
            title: "Total usage",
            icon: .providerMark("cursor"),
            kind: .percent,
            used: 99.6,
            limit: 100
        )
        XCTAssertEqual(nearlyFull.valueText, "100%")
        XCTAssertEqual(nearlyFull.fraction, 1, accuracy: 0.0001)
    }

    func testOnDemandDollarLimitAppendsLimitNoun() {
        let onDemand = WidgetData(
            title: "On-Demand",
            icon: .providerMark("cursor"),
            kind: .dollars,
            used: 0,
            limit: 100,
            limitNoun: "limit"
        )
        XCTAssertEqual(onDemand.boundedSubtitle, "$100 limit")
    }

    func testCreditsDollarLimitAppendsLimitNoun() {
        // Matches the original OpenUsage, which renders every bounded dollar metric's subtitle as
        // "$X limit" — never "total".
        let credits = WidgetData(
            title: "Credits",
            icon: .providerMark("cursor"),
            kind: .dollars,
            used: 0,
            limit: 20,
            limitNoun: "limit"
        )
        XCTAssertEqual(credits.boundedSubtitle, "$20 limit")
    }

    func testRequestsShowsBillingResetInsteadOfSuffix() {
        // The requests tile resets on the billing cycle, so it shows the cadence rather than "requests".
        let requests = WidgetData(
            title: "Requests",
            icon: .providerMark("cursor"),
            kind: .count,
            used: 0,
            limit: 500,
            countSuffix: "requests",
            periodDurationMs: CursorUsageMapper.billingPeriodMs
        )
        XCTAssertEqual(requests.boundedSubtitle, "Resets in 30d 0h")
    }

    func testCreditValuesFloorAndClampBalance() {
        var data = WidgetData(title: "Extra Usage", icon: .providerMark("codex"), kind: .dollars, used: 0, limit: nil)
        data.values = CodexUsageMapper.creditValues(remaining: 820.9)
        XCTAssertEqual(data.unboundedDetail, "$32.80 · 820 credits")
        // An exhausted/negative balance clamps to a real, measured zero — "$0.00 · 0 credits", not "No data".
        data.values = CodexUsageMapper.creditValues(remaining: -5)
        XCTAssertEqual(data.unboundedDetail, "$0.00 · 0 credits")
    }

    func testCreditsRenderUpToOneDecimalPlace() {
        let credits = WidgetData(
            title: "Extra Usage",
            icon: .providerMark("codex"),
            kind: .count,
            used: 820.55,
            limit: nil,
            countSuffix: "credits",
            unboundedValueWord: "left"
        )

        XCTAssertEqual(credits.valueText, "820.6")
        XCTAssertEqual(credits.unboundedDetail, "820.6 credits left")
    }
}

import XCTest
@testable import OpenUsage

/// The one number→text place. `.tray` is the menu-bar form (shortest), `.row` the popover form
/// (abbreviated but money keeps cents), `.full` the exact tooltip/headline form. These cases pin the
/// behavior the old `WidgetData.format`, `MenuBarContent.compactValue`, and `formatTokens` each had.
final class MetricFormatterTests: XCTestCase {
    func testDollarsAbbreviateAboveAThousandPerStyle() {
        // Tray: whole dollars under $1k, abbreviated above.
        XCTAssertEqual(MetricFormatter.number(42, kind: .dollars, style: .tray), "$42")
        XCTAssertEqual(MetricFormatter.number(2059.07, kind: .dollars, style: .tray), "$2.1K")
        // Row: full cents under $1k, abbreviated with one decimal above (matching token counts).
        XCTAssertEqual(MetricFormatter.number(40.76, kind: .dollars, style: .row), "$40.76")
        XCTAssertEqual(MetricFormatter.number(2059.07, kind: .dollars, style: .row), "$2.1K")
        // Full: every digit, grouped.
        XCTAssertEqual(MetricFormatter.number(2059.07, kind: .dollars, style: .full), "$2,059.07")
    }

    func testCountsAbbreviateInTrayAndRowButKeepEveryDigitInFull() {
        XCTAssertEqual(MetricFormatter.number(56_904_995, kind: .count, style: .tray), "56.9M")
        XCTAssertEqual(MetricFormatter.number(56_904_995, kind: .count, style: .row), "56.9M")
        XCTAssertEqual(MetricFormatter.number(56_904_995, kind: .count, style: .full), "56,904,995")
        XCTAssertEqual(MetricFormatter.number(1_485_201_513, kind: .count, style: .row), "1.5B")
        // Below 1,000, up to one decimal survives (a fractional credit balance).
        XCTAssertEqual(MetricFormatter.number(820.6, kind: .count, style: .row), "820.6")
    }

    func testPercentRoundsToWholeInEveryStyle() {
        XCTAssertEqual(MetricFormatter.number(95, kind: .percent, style: .full), "95%")
        XCTAssertEqual(MetricFormatter.number(95.4, kind: .percent, style: .tray), "95%")
    }

    func testPercentClampsOutOfRangeSamples() {
        // Percent is a bounded 0...100 domain: a bad sample (a provider reporting a negative or >100
        // utilization) must never print "-5%" or "130%" — it clamps to the nearest bound. (#703)
        XCTAssertEqual(MetricFormatter.number(-5, kind: .percent, style: .full), "0%")
        XCTAssertEqual(MetricFormatter.number(-5, kind: .percent, style: .tray), "0%")
        XCTAssertEqual(MetricFormatter.number(130, kind: .percent, style: .full), "100%")
        XCTAssertEqual(MetricFormatter.number(100.6, kind: .percent, style: .row), "100%")
    }

    func testValueStringAppendsUnitLabelWhenPresent() {
        let credits = MetricValue(number: 772, kind: .count, label: "credits")
        XCTAssertEqual(MetricFormatter.string(for: credits, style: .row), "772 credits")
        XCTAssertEqual(MetricFormatter.string(for: credits, style: .full), "772 credits")
        // Tokens carry no label, so nothing is appended in any style.
        let tokens = MetricValue(number: 56_904_995, kind: .count)
        XCTAssertEqual(MetricFormatter.string(for: tokens, style: .row), "56.9M")
        XCTAssertEqual(MetricFormatter.string(for: tokens, style: .full), "56,904,995")
    }

    func testCostPerMtokAppendsUnitToDollarFormatting() {
        XCTAssertEqual(MetricFormatter.costPerMtok(32, style: .tray), "$32/MTok")
        XCTAssertEqual(MetricFormatter.costPerMtok(32.1, style: .row), "$32.10/MTok")
        XCTAssertEqual(MetricFormatter.costPerMtok(32.1, style: .full), "$32.10/MTok")
        XCTAssertEqual(MetricFormatter.costPerMtok(2059.07, style: .tray), "$2.1K/MTok")
        XCTAssertEqual(MetricFormatter.costPerMtok(2059.07, style: .full), "$2,059.07/MTok")
    }

    func testTotalSpendRingCenterSplitsValueAndUnit() {
        let spend = MetricFormatter.totalSpendRingCenter(533, metric: .cost)
        XCTAssertEqual(spend.primary, "$533")
        XCTAssertEqual(spend.unit, "dollars")

        let spendAbbrev = MetricFormatter.totalSpendRingCenter(2059.07, metric: .cost)
        XCTAssertEqual(spendAbbrev.primary, "$2.1K")
        XCTAssertEqual(spendAbbrev.unit, "dollars")

        let tokens = MetricFormatter.totalSpendRingCenter(12_400_000, metric: .tokens)
        XCTAssertEqual(tokens.primary, "12.4")
        XCTAssertEqual(tokens.unit, "million")

        let billions = MetricFormatter.totalSpendRingCenter(1_500_000_000, metric: .tokens)
        XCTAssertEqual(billions.primary, "1.5")
        XCTAssertEqual(billions.unit, "billion")

        let smallTokens = MetricFormatter.totalSpendRingCenter(820.6, metric: .tokens)
        XCTAssertEqual(smallTokens.primary, "820.6")
        XCTAssertEqual(smallTokens.unit, "tokens")

        let rate = MetricFormatter.totalSpendRingCenter(1.37, metric: .costPerMtok)
        XCTAssertEqual(rate.primary, "$1.37")
        XCTAssertEqual(rate.unit, "MTok")
    }
}

import XCTest
@testable import OpenUsage

/// The "No usage in this period" note is scoped to spend-period rows — Today / Yesterday /
/// Last 30 Days — through `WidgetData.isUsagePeriod`. A balance/availability row that happens to read
/// zero (Codex "Rate Limit Resets" with none available, an exhausted "Extra Usage" credit) is depleted,
/// not idle, so it stays off the note even though every selected value is zero.
@MainActor
final class WidgetUsagePeriodTests: XCTestCase {
    private let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))

    func testSpendTilesAreUsagePeriods() {
        let tiles = WidgetDescriptor.spendTiles(provider: provider)
        XCTAssertEqual(tiles.count, 3)
        XCTAssertTrue(tiles.allSatisfy { $0.sample.isUsagePeriod })
    }

    func testValuesAndCombinedDefaultToNotUsagePeriod() {
        // The exact shape the Codex balance rows use: `.values(...)` for Rate Limit Resets and
        // `.combined(...)` for Extra Usage credits, neither opting into a usage period.
        let resets = WidgetDescriptor.values(id: "codex.rateLimitResets", provider: provider,
                                             title: "Rate Limit Resets", metricLabel: "Rate Limit Resets")
        let credits = WidgetDescriptor.combined(id: "codex.credits", provider: provider,
                                                title: "Extra Usage", metricLabel: "Credits")
        XCTAssertFalse(resets.sample.isUsagePeriod)
        XCTAssertFalse(credits.sample.isUsagePeriod)
    }

    func testCodexBalanceRowsAreNotUsagePeriods() {
        let descriptors = CodexProvider().widgetDescriptors
        XCTAssertEqual(descriptors.first { $0.id == "codex.rateLimitResets" }?.sample.isUsagePeriod, false)
        XCTAssertEqual(descriptors.first { $0.id == "codex.credits" }?.sample.isUsagePeriod, false)
        // The spend tiles on the same provider do carry the flag.
        XCTAssertEqual(descriptors.first { $0.id == "codex.today" }?.sample.isUsagePeriod, true)
    }

    /// A depleted balance (every value zero, not a usage period): `isZeroUsage` is still true, but the
    /// note gate `isZeroUsage && isUsagePeriod` is false, so no "No usage in this period" note shows.
    func testZeroBalanceRowIsGatedOutOfTheNote() {
        var row = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"), kind: .count, used: 0,
                             limit: nil, values: [MetricValue(number: 0, kind: .count)])
        row.isUsagePeriod = false
        XCTAssertTrue(row.isZeroUsage)
        XCTAssertFalse(row.isZeroUsage && row.isUsagePeriod)
    }

    /// A zero spend day (every value zero, a usage period): both true, so the note shows.
    func testZeroSpendPeriodKeepsTheNote() {
        var row = WidgetData(title: "Today", icon: .providerMark("codex"), kind: .dollars, used: 0, limit: nil,
                             values: [MetricValue(number: 0, kind: .dollars),
                                      MetricValue(number: 0, kind: .count)])
        row.isUsagePeriod = true
        XCTAssertTrue(row.isZeroUsage)
        XCTAssertTrue(row.isZeroUsage && row.isUsagePeriod)
    }

    func testUnknownModelWarningTooltipSingularAndPlural() {
        var single = WidgetData(title: "Today", icon: .providerMark("cursor"), kind: .dollars, used: 0, limit: nil,
                                values: [MetricValue(number: 1.0, kind: .dollars)])
        single.unknownModels = ["GLM 5.2"]
        XCTAssertTrue(single.hasUnknownModels)
        XCTAssertEqual(single.unknownModelTooltip, "Unknown model found\n- GLM 5.2")

        var many = single
        many.unknownModels = ["GLM 5.2", "Some Other Model"]
        XCTAssertEqual(many.unknownModelTooltip, "Unknown models found\n- GLM 5.2\n- Some Other Model")
    }

    func testNoUnknownModelsLeavesTriangleOff() {
        var row = WidgetData(title: "Yesterday", icon: .providerMark("cursor"), kind: .dollars, used: 0, limit: nil,
                             values: [MetricValue(number: 1.0, kind: .dollars)])
        XCTAssertFalse(row.hasUnknownModels)
        XCTAssertNil(row.unknownModelTooltip)
        // A no-data tile never raises the warning even if names somehow rode along.
        row.unknownModels = ["GLM 5.2"]
        row.hasData = false
        XCTAssertFalse(row.hasUnknownModels)
        XCTAssertNil(row.unknownModelTooltip)
    }

    func testZeroSpendPeriodWithSourceNoteKeepsTheNoUsageTooltip() {
        var row = WidgetData(title: "Last 30 Days", icon: .providerMark("cursor"), kind: .dollars, used: 0,
                             limit: nil,
                             values: [MetricValue(number: 0, kind: .dollars),
                                      MetricValue(number: 0, kind: .count, label: "tokens")])
        row.isUsagePeriod = true
        row.valueTooltipNote = WidgetData.cursorUsageHistoryNote

        XCTAssertEqual(row.unboundedDetail, "$0.00 · 0 tokens")
        XCTAssertEqual(row.unboundedValueTooltip, "No usage in this period\n\(WidgetData.cursorUsageHistoryNote)")
    }
}

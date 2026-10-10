import XCTest
@testable import OpenUsage

final class CursorGrokBotPricingTests: XCTestCase {
    func testGrokBotUsageEventsPriceIntoEverySpendRange() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let pricing = TestPricing.bundled

        // Exercise all four token buckets both below and above long-context thresholds.
        for scale in [1, 1_000] {
            var rows: [CursorUsageRow] = []
            for date in [now, yesterday] {
                for model in ["grok-bot-default", "grok-bot-automation", "grok-bot-cua"] {
                    let tokens = TokenBreakdown(
                        input: 1_000 * scale,
                        cacheWrite5m: 2_000 * scale,
                        cacheRead: 3_000 * scale,
                        output: 4_000 * scale
                    )
                    rows.append(CursorUsageRow(
                        date: date,
                        model: model,
                        tokens: tokens,
                        imputedCostDollars: pricing.estimatedCostDollars(
                            model: model,
                            tokens: tokens,
                            applyLongContextRates: false
                        )
                    ))
                }
            }
            XCTAssertEqual(rows.count, 6)
            for row in rows {
                // Default: $4 input/write, $1 read, $12 output per million.
                // Automation and CUA use Grok 4.7 base: $2 input/write, $0.50 read, $6 output.
                let cost = row.model == "grok-bot-default" ? 0.063 : 0.0315
                XCTAssertEqual(try XCTUnwrap(row.imputedCostDollars), cost * Double(scale), accuracy: 1e-9)
            }

            var lines: [MetricLine] = []
            _ = CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: pricing, to: &lines)

            for (label, days) in [("Today", 1), ("Yesterday", 1), ("Last 30 Days", 2)] {
                let line = try XCTUnwrap(lines.first { $0.label == label })
                guard case .values(_, let values, _, _, let unknownModels, _) = line else {
                    return XCTFail("Expected spend values for \(label)")
                }
                // Cursor rounds each day's combined $0.126 estimate to cents before summing days.
                let dailyDollars = scale == 1 ? 0.13 : 126.0
                let dollars = dailyDollars * Double(days)
                XCTAssertEqual(values, [
                    MetricValue(number: dollars, kind: .dollars, estimated: true),
                    MetricValue(number: Double(30_000 * scale * days), kind: .count, label: "tokens")
                ], label)
                XCTAssertTrue(unknownModels.isEmpty, label)
            }
        }
    }
}

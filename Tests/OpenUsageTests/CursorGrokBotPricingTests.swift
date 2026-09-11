import XCTest
@testable import OpenUsage

final class CursorGrokBotPricingTests: XCTestCase {
    func testGrokBotCSVPricesFlowIntoEverySpendRange() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let formatter = ISO8601DateFormatter()

        // Exercise all four token buckets both below and above long-context thresholds.
        // CSV rows aggregate requests; their size must not add a long-context surcharge.
        for scale in [1, 1_000] {
            var csv = "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost\n"
            for date in [now, yesterday] {
                for model in ["grok-bot-default", "grok-bot-automation", "grok-bot-cua"] {
                    csv += "\(formatter.string(from: date)),\(model),\(2_000 * scale),\(1_000 * scale),\(3_000 * scale),\(4_000 * scale),0\n"
                }
            }
            let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)
            XCTAssertEqual(parsed.rejectedRowCount, 0)
            XCTAssertEqual(parsed.rows.count, 6)
            for row in parsed.rows {
                if row.model == "grok-bot-cua" {
                    XCTAssertNil(row.imputedCostDollars)
                } else {
                    // Default: $4 input/write, $1 read, $12 output per million.
                    // Automation: $2 input/write, $0.50 read, $6 output per million.
                    let cost = row.model == "grok-bot-default" ? 0.063 : 0.0315
                    XCTAssertEqual(try XCTUnwrap(row.imputedCostDollars), cost * Double(scale), accuracy: 1e-9)
                }
            }

            var lines: [MetricLine] = []
            _ = CursorUsageMapper.appendSpendLines(rows: parsed.rows, now: now, pricing: TestPricing.bundled, to: &lines)

            for (label, days) in [("Today", 1), ("Yesterday", 1), ("Last 30 Days", 2)] {
                let line = try XCTUnwrap(lines.first { $0.label == label })
                guard case .values(_, let values, _, _, let unknownModels, _) = line else {
                    return XCTFail("Expected spend values for \(label)")
                }
                // Cursor rounds each day's combined $0.0945 estimate to cents before summing days.
                let dailyDollars = scale == 1 ? 0.09 : 94.5
                let dollars = dailyDollars * Double(days)
                XCTAssertEqual(values, [
                    MetricValue(number: dollars, kind: .dollars, estimated: true),
                    MetricValue(number: Double(20_000 * scale * days), kind: .count, label: "tokens")
                ], label)
                XCTAssertEqual(unknownModels, ["grok-bot-cua"], label)
            }
        }
    }
}

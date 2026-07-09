import XCTest
@testable import OpenUsage

/// `WidgetData.isZeroUsage` distinguishes a real zero-usage period (every selected value is 0) from
/// "no data" and from small non-zero usage, so an empty row ("$0.00 · 0 tokens") can carry a "no usage"
/// note instead of a figures reveal.
final class WidgetZeroUsageTests: XCTestCase {
    private func row(values: [MetricValue], hasData: Bool = true) -> WidgetData {
        WidgetData(title: "Today", icon: .providerMark("codex"), kind: .count, used: 0, limit: nil,
                   hasData: hasData, values: values)
    }

    func testAllZeroValuesAreZeroUsage() {
        let data = row(values: [MetricValue(number: 0, kind: .dollars),
                                MetricValue(number: 0, kind: .count)])
        XCTAssertTrue(data.isZeroUsage)
    }

    func testSmallNonZeroValuesAreNotZeroUsage() {
        let data = row(values: [MetricValue(number: 5, kind: .dollars),
                                MetricValue(number: 200, kind: .count)])
        XCTAssertFalse(data.isZeroUsage)
    }

    func testNoDataIsNotZeroUsage() {
        let data = row(values: [MetricValue(number: 0, kind: .count)], hasData: false)
        XCTAssertFalse(data.isZeroUsage)
    }

    func testEmptyValuesAreNotZeroUsage() {
        XCTAssertFalse(row(values: []).isZeroUsage)
    }
}

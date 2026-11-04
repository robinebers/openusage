import XCTest
@testable import OpenUsage

final class MeterSeverityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func percentData(used: Double, limit: Double? = 100,
                             displayMode: WidgetDisplayMode = .used) -> WidgetData {
        WidgetData(title: "Session", kind: .percent,
                   used: used, limit: limit, displayMode: displayMode)
    }

    func testTheBandsUseRoundedPercentagesLeft() {
        let cases: [(used: Double, severity: WidgetData.MeterSeverity)] = [
            (69.4, .normal), (69.6, .warning), (70, .warning),
            (89.4, .warning), (89.6, .critical), (90, .critical)
        ]

        for testCase in cases {
            XCTAssertEqual(percentData(used: testCase.used).severity, testCase.severity, "used: \(testCase.used)")
        }
    }

    func testNonPercentKindsBandOnTheirShareOfTheLimit() {
        let dollars = WidgetData(title: "Credits", kind: .dollars, used: 45, limit: 50)
        XCTAssertEqual(dollars.severity, .critical)

        XCTAssertEqual(WidgetData(title: "Requests", kind: .count, used: 375, limit: 500).severity, .warning)
        XCTAssertEqual(WidgetData(title: "Requests", kind: .count, used: 240, limit: 500).severity, .normal)
    }

    func testUnboundedZeroLimitAndUnreportedMetricsStayNormal() {
        XCTAssertEqual(percentData(used: 99, limit: nil).severity, .normal)
        XCTAssertEqual(percentData(used: 99, limit: 0).severity, .normal)
        var data = percentData(used: 95)
        data.hasData = false
        XCTAssertEqual(data.severity, .normal)
        XCTAssertEqual(data.meterState(now: now), .noData)
    }
}

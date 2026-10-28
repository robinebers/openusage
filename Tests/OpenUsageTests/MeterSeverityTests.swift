import XCTest
@testable import OpenUsage

final class MeterSeverityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func percentData(used: Double, limit: Double? = 100,
                             displayMode: WidgetDisplayMode = .used) -> WidgetData {
        WidgetData(title: "Session", kind: .percent,
                   used: used, limit: limit, displayMode: displayMode)
    }

    private func pacedData(used: Double, elapsed: Double) -> WidgetData {
        var data = percentData(used: used)
        data.resetsAt = now.addingTimeInterval(week * (1 - elapsed))
        data.periodDurationMs = Int(week * 1000)
        return data
    }

    private func severity(_ data: WidgetData) -> WidgetData.MeterSeverity? {
        data.meterState(now: now).severity
    }

    func testTheBandsUseRoundedPercentages() {
        let cases: [(used: Double, severity: WidgetData.MeterSeverity)] = [
            (0, .normal), (74, .normal), (74.4, .normal), (74.6, .warning), (75, .warning), (76, .warning),
            (80, .warning), (89.4, .warning), (89.6, .critical), (90, .critical)
        ]

        for testCase in cases {
            XCTAssertEqual(severity(percentData(used: testCase.used)), testCase.severity, "used: \(testCase.used)")
        }
        XCTAssertEqual(percentData(used: 100).meterState(now: now), .spent)
        XCTAssertEqual(percentData(used: 130).meterState(now: now), .spent)
    }

    func testWithAResetWindowTheColourIsThePaceVerdict() {
        XCTAssertEqual(severity(pacedData(used: 59, elapsed: 0.333)), .critical)
        XCTAssertEqual(severity(pacedData(used: 66, elapsed: 0.363)), .critical)
        XCTAssertEqual(severity(pacedData(used: 93, elapsed: 0.1)), .critical)
        XCTAssertEqual(severity(pacedData(used: 76, elapsed: 0.74)), .critical)
        XCTAssertEqual(severity(pacedData(used: 85, elapsed: 0.9)), .warning)
        XCTAssertEqual(severity(pacedData(used: 49, elapsed: 0.5)), .warning)
        XCTAssertEqual(severity(pacedData(used: 85, elapsed: 0.96)), .normal)
        XCTAssertEqual(severity(pacedData(used: 27, elapsed: 0.9)), .normal)
        XCTAssertEqual(severity(pacedData(used: 17, elapsed: 0.25)), .normal)
        XCTAssertEqual(severity(pacedData(used: 4, elapsed: 0.02)), .normal)
        XCTAssertEqual(pacedData(used: 4, elapsed: 0.02).meterState(now: now), .level(.normal))
    }

    func testTheColourNeverCoolsAsTheShareUsedRises() {
        func rank(_ severity: WidgetData.MeterSeverity?) -> Int {
            switch severity {
            case nil: return -1
            case .normal: return 0
            case .warning: return 1
            case .critical: return 2
            }
        }
        var previous = -1
        for tenths in 0...1000 {
            let used = Double(tenths) / 10
            let current = rank(severity(pacedData(used: used, elapsed: 0.5)))
            XCTAssertGreaterThanOrEqual(current, previous, "\(used)% used cooled the colour")
            previous = current
        }
        XCTAssertEqual(previous, 2)
    }

    func testRemainderRoundingToZeroIsSpent() {
        XCTAssertEqual(pacedData(used: 99.6, elapsed: 0.997).meterState(now: now), .spent)
        let dollars = WidgetData(title: "Credits", kind: .dollars,
                                 used: 99.996, limit: 100)
        XCTAssertEqual(dollars.meterState(now: now), .spent)
    }

    func testSeverityIgnoresTheUsedLeftDisplayMode() {
        XCTAssertEqual(severity(percentData(used: 95, displayMode: .remaining)), .critical)
        XCTAssertEqual(severity(percentData(used: 76, displayMode: .remaining)), .warning)
        XCTAssertEqual(severity(percentData(used: 5, displayMode: .remaining)), .normal)
    }

    func testNonPercentKindsBandOnTheirShareOfTheLimit() {
        let dollars = WidgetData(title: "Credits", kind: .dollars,
                                 used: 45, limit: 50)
        XCTAssertEqual(severity(dollars), .critical)

        let counts = WidgetData(title: "Requests", kind: .count,
                                used: 375, limit: 500)
        XCTAssertEqual(severity(counts), .warning)
        XCTAssertEqual(severity(WidgetData(title: "Requests", kind: .count,
                                           used: 370, limit: 500)), .normal)
    }

    func testUnboundedAndZeroLimitMetricsStayNormal() {
        XCTAssertEqual(severity(percentData(used: 99, limit: nil)), .normal)
        XCTAssertEqual(severity(percentData(used: 99, limit: 0)), .normal)
    }

    func testNoDataHasNoSeverity() {
        var data = percentData(used: 50)
        data.hasData = false
        XCTAssertEqual(data.meterState(now: now), .noData)
        XCTAssertNil(severity(data))
    }
}

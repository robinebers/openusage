import XCTest
@testable import OpenUsage

final class MetricFormatterTests: XCTestCase {
    func testDollarsAbbreviateAboveAThousandPerStyle() {
        XCTAssertEqual(MetricFormatter.number(42, kind: .dollars, style: .tray), "$42")
        XCTAssertEqual(MetricFormatter.number(129.81, kind: .dollars, style: .tray), "$130")
        XCTAssertEqual(MetricFormatter.number(2059.07, kind: .dollars, style: .tray), "$2.1K")
        XCTAssertEqual(MetricFormatter.number(40.76, kind: .dollars, style: .row), "$40.76")
        XCTAssertEqual(MetricFormatter.number(2059.07, kind: .dollars, style: .row), "$2.1K")
    }

    func testCountsAbbreviateInTrayAndRow() {
        XCTAssertEqual(MetricFormatter.number(56_904_995, kind: .count, style: .tray), "56.9M")
        XCTAssertEqual(MetricFormatter.number(56_904_995, kind: .count, style: .row), "56.9M")
        XCTAssertEqual(MetricFormatter.number(1_485_201_513, kind: .count, style: .row), "1.5B")
        XCTAssertEqual(MetricFormatter.number(820.6, kind: .count, style: .row), "820.6")
    }

    func testPercentRoundsToWholeInEveryStyle() {
        XCTAssertEqual(MetricFormatter.number(95, kind: .percent, style: .row), "95%")
        XCTAssertEqual(MetricFormatter.number(95.4, kind: .percent, style: .tray), "95%")
    }

    func testPercentClampsOutOfRangeSamples() {
        XCTAssertEqual(MetricFormatter.number(-5, kind: .percent, style: .row), "0%")
        XCTAssertEqual(MetricFormatter.number(-5, kind: .percent, style: .tray), "0%")
        XCTAssertEqual(MetricFormatter.number(130, kind: .percent, style: .tray), "100%")
        XCTAssertEqual(MetricFormatter.number(100.6, kind: .percent, style: .row), "100%")
    }

    func testValueStringAppendsUnitLabelWhenPresent() {
        let credits = MetricValue(number: 772, kind: .count, label: "credits")
        XCTAssertEqual(MetricFormatter.string(for: credits, style: .row), "772 credits")
        XCTAssertEqual(MetricFormatter.string(for: credits, style: .tray), "772 credits")
        let tokens = MetricValue(number: 56_904_995, kind: .count)
        XCTAssertEqual(MetricFormatter.string(for: tokens, style: .row), "56.9M")
        XCTAssertEqual(MetricFormatter.string(for: tokens, style: .tray), "56.9M")
    }
}

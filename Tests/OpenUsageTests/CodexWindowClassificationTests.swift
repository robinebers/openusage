import XCTest
@testable import OpenUsage

final class CodexWindowClassificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAWeeklyWindowInThePrimarySlotIsTheWeeklyMeter() throws {
        let meters = try windows(#"{"primary_window":{"used_percent":30,"limit_window_seconds":604800,"reset_after_seconds":100}}"#)

        XCTAssertEqual(meters.map(\.label), ["Weekly"])
        XCTAssertEqual(meters.first?.used, 30)
        XCTAssertEqual(meters.first?.periodMs, MetricPeriod.weekMs)
        XCTAssertEqual(meters.first?.resetsAt, now.addingTimeInterval(100))
    }

    func testSwappedSlotsAreReadByDuration() throws {
        let meters = try windows(
            #"{"primary_window":{"used_percent":70,"limit_window_seconds":604800},"secondary_window":{"used_percent":20,"limit_window_seconds":18000}}"#
        )

        XCTAssertEqual(meters.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(meters.map(\.used), [20, 70])
    }

    func testAnUnfamiliarDurationStaysInItsSlotWithItsOwnPeriod() throws {
        let meters = try windows(
            #"{"primary_window":{"used_percent":10,"limit_window_seconds":3600},"secondary_window":{"used_percent":40,"limit_window_seconds":2592000}}"#
        )

        XCTAssertEqual(meters.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(meters.map(\.used), [10, 40])
        XCTAssertEqual(meters.map(\.periodMs), [3_600_000, 2_592_000_000])
    }

    func testAMatchedWindowWithoutAPercentShowsNothingAndBorrowsNoOtherWindow() throws {
        let meters = try windows(
            #"{"primary_window":{"limit_window_seconds":604800},"secondary_window":{"used_percent":40,"limit_window_seconds":86400}}"#
        )

        XCTAssertEqual(meters.map(\.label), [])
    }

    func testAHeaderPercentAloneIsTheSlotsMeterWithTheDefaultPeriod() throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["x-codex-primary-used-percent": "55"],
            body: Data(#"{"rate_limit":{}}"#.utf8)
        )
        let meters = Self.meters(try CodexUsageMapper.mapUsageResponse(response, now: now).lines)

        XCTAssertEqual(meters.map(\.label), ["Session"])
        XCTAssertEqual(meters.first?.used, 55)
        XCTAssertEqual(meters.first?.periodMs, MetricPeriod.sessionMs)
        XCTAssertNil(meters.first?.resetsAt)
    }

    private func windows(_ rateLimit: String) throws -> [(label: String, used: Double, resetsAt: Date?, periodMs: Int?)] {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"rate_limit":\#(rateLimit)}"#.utf8))
        return Self.meters(try CodexUsageMapper.mapUsageResponse(response, now: now).lines)
    }

    private static func meters(_ lines: [MetricLine]) -> [(label: String, used: Double, resetsAt: Date?, periodMs: Int?)] {
        lines.compactMap { line in
            guard case .progress(let label, let used, 100, .percent, let resetsAt, let periodMs) = line else { return nil }
            return (label, used, resetsAt, periodMs)
        }
    }
}

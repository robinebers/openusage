import XCTest
@testable import OpenUsage

/// Go plan meters from `/zen/go/v1/usage`: percent format, resets, periods, and boundary failures.
final class OpenCodeUsageMapperTests: XCTestCase {
    private let sampleBody: [String: Any] = [
        "usage": [
            "rolling": ["status": "ok", "percent": 12, "resetsAt": "2026-07-12T13:30:00.662Z"],
            "weekly": ["status": "ok", "percent": 8, "resetsAt": "2026-07-13T00:00:00.662Z"],
            "monthly": ["status": "rate-limited", "percent": 100, "resetsAt": "2026-08-04T11:18:32.662Z"]
        ]
    ]

    func testMeterLinesMatchDashboardPercentsAndResets() throws {
        let lines = try OpenCodeUsageMapper.meterLines(body: sampleBody)
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly", "Monthly"])

        guard case let .progress(_, sessionUsed, sessionLimit, sessionFormat, sessionReset, sessionPeriod, _) = lines[0] else {
            return XCTFail("session is not a progress line")
        }
        XCTAssertEqual(sessionUsed, 12)
        XCTAssertEqual(sessionLimit, 100)
        XCTAssertEqual(sessionFormat, .percent)
        XCTAssertEqual(sessionReset, OpenUsageISO8601.date(from: "2026-07-12T13:30:00.662Z"))
        XCTAssertEqual(sessionPeriod, MetricPeriod.sessionMs)

        guard case let .progress(_, weeklyUsed, _, weeklyFormat, weeklyReset, weeklyPeriod, _) = lines[1] else {
            return XCTFail("weekly is not a progress line")
        }
        XCTAssertEqual(weeklyUsed, 8)
        XCTAssertEqual(weeklyFormat, .percent)
        XCTAssertEqual(weeklyReset, OpenUsageISO8601.date(from: "2026-07-13T00:00:00.662Z"))
        XCTAssertEqual(weeklyPeriod, MetricPeriod.weekMs)

        guard case let .progress(_, monthlyUsed, _, monthlyFormat, _, monthlyPeriod, _) = lines[2] else {
            return XCTFail("monthly is not a progress line")
        }
        XCTAssertEqual(monthlyUsed, 100)
        XCTAssertEqual(monthlyFormat, .percent)
        XCTAssertEqual(monthlyPeriod, MetricPeriod.monthMs)
    }

    func testZeroPercentIsARealMeterNotNoData() throws {
        let body: [String: Any] = [
            "usage": [
                "rolling": ["percent": 0, "resetsAt": "2026-07-12T17:00:00.000Z"],
                "weekly": ["percent": 0, "resetsAt": "2026-07-13T00:00:00.000Z"],
                "monthly": ["percent": 0, "resetsAt": "2026-08-04T00:00:00.000Z"]
            ]
        ]
        let lines = try OpenCodeUsageMapper.meterLines(body: body)
        guard case let .progress(_, used, limit, format, _, _, _) = lines[0] else {
            return XCTFail("session is not a progress line")
        }
        XCTAssertEqual(used, 0)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
    }

    func testPercentIsClamped() throws {
        let body: [String: Any] = [
            "usage": [
                "rolling": ["percent": 150],
                "weekly": ["percent": -4],
                "monthly": ["percent": 35]
            ]
        ]
        let lines = try OpenCodeUsageMapper.meterLines(body: body)
        guard case let .progress(_, rolling, _, _, _, _, _) = lines[0],
              case let .progress(_, weekly, _, _, _, _, _) = lines[1] else {
            return XCTFail("expected progress lines")
        }
        XCTAssertEqual(rolling, 100)
        XCTAssertEqual(weekly, 0)
    }

    func testHTTPResponseBodyRoundTrip() throws {
        let data = try JSONSerialization.data(withJSONObject: sampleBody)
        let lines = try OpenCodeUsageMapper.meterLines(HTTPResponse(statusCode: 200, headers: [:], body: data))
        XCTAssertEqual(lines.count, 3)
    }

    func testMissingUsageOrWindowIsInvalid() {
        XCTAssertThrowsError(try OpenCodeUsageMapper.meterLines(body: [:])) { error in
            XCTAssertEqual(error as? OpenCodeUsageError, .invalidResponse)
        }
        XCTAssertThrowsError(try OpenCodeUsageMapper.meterLines(body: ["usage": ["weekly": ["percent": 1]]])) { error in
            XCTAssertEqual(error as? OpenCodeUsageError, .invalidResponse)
        }
    }

    func testErrorTypeFromDocumentedErrorBody() {
        let entitlement = """
        {"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}
        """.data(using: .utf8)!
        let auth = """
        {"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}
        """.data(using: .utf8)!
        XCTAssertEqual(
            OpenCodeUsageMapper.errorType(in: HTTPResponse(statusCode: 403, headers: [:], body: entitlement)),
            "EntitlementError"
        )
        XCTAssertEqual(
            OpenCodeUsageMapper.errorType(in: HTTPResponse(statusCode: 401, headers: [:], body: auth)),
            "AuthError"
        )
        XCTAssertNil(OpenCodeUsageMapper.errorType(in: HTTPResponse(statusCode: 403, headers: [:], body: Data("<html>".utf8))))
    }
}

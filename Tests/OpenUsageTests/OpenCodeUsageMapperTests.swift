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

    /// An untouched rolling window has nothing to roll off, so the API answers `resetsAt = now + 5h`
    /// and slides it forward every request. That placeholder is dropped at capture time so the Session
    /// row reads "Not started" off the missing reset rather than counting down to a moving target.
    func testUntouchedRollingWindowDropsPlaceholderReset() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let placeholder = capturedAt.addingTimeInterval(5 * 3600 + 0.8) // live endpoint overshoots slightly
        let body: [String: Any] = [
            "usage": [
                "rolling": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: placeholder)],
                "weekly": ["percent": 1, "resetsAt": OpenUsageISO8601.string(from: capturedAt.addingTimeInterval(3 * 86_400))],
                "monthly": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: capturedAt.addingTimeInterval(20 * 86_400))]
            ]
        ]
        let lines = try OpenCodeUsageMapper.meterLines(body: body, capturedAt: capturedAt)
        guard case let .progress(_, used, _, _, resetsAt, _, _) = lines[0] else {
            return XCTFail("session is not a progress line")
        }
        XCTAssertEqual(used, 0)
        XCTAssertNil(resetsAt)
    }

    /// The reported bug at the point it matters most: a newly started session still reads 0%, but its
    /// reset has already moved inside the five-hour period. Thirty and sixty seconds are both well past
    /// the upstream response's unavoidable whole-second ambiguity and must keep the countdown.
    func testSubOnePercentRollingWindowKeepsAnchoredReset() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let period = TimeInterval(MetricPeriod.sessionMs) / 1000
        for age in [30.0, 60.0] {
            let anchored = capturedAt.addingTimeInterval(period - age)
            let body: [String: Any] = [
                "usage": [
                    "rolling": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: anchored)],
                    "weekly": ["percent": 1, "resetsAt": OpenUsageISO8601.string(from: capturedAt.addingTimeInterval(3 * 86_400))],
                    "monthly": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: capturedAt.addingTimeInterval(20 * 86_400))]
                ]
            ]
            let lines = try OpenCodeUsageMapper.meterLines(body: body, capturedAt: capturedAt)
            guard case let .progress(_, used, _, _, resetsAt, _, _) = lines[0] else {
                return XCTFail("session is not a progress line")
            }
            XCTAssertEqual(used, 0)
            XCTAssertEqual(resetsAt, anchored, "active session aged \(age)s lost its reset")
        }
    }

    func testPlaceholderComparisonIsBoundedOnBothSides() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let period = TimeInterval(MetricPeriod.sessionMs) / 1000

        func mappedReset(offsetFromFullPeriod offset: TimeInterval) throws -> Date? {
            let reset = capturedAt.addingTimeInterval(period + offset)
            let body: [String: Any] = [
                "usage": [
                    "rolling": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: reset)],
                    "weekly": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: capturedAt.addingTimeInterval(3 * 86_400))],
                    "monthly": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: capturedAt.addingTimeInterval(20 * 86_400))]
                ]
            ]
            let lines = try OpenCodeUsageMapper.meterLines(body: body, capturedAt: capturedAt)
            guard case let .progress(_, _, _, _, resetsAt, _, _) = lines[0] else {
                XCTFail("session is not a progress line")
                return nil
            }
            return resetsAt
        }

        XCTAssertNil(try mappedReset(offsetFromFullPeriod: -OpenCodeUsageMapper.placeholderResetTolerance))
        XCTAssertNil(try mappedReset(offsetFromFullPeriod: OpenCodeUsageMapper.placeholderResetTolerance))
        XCTAssertNotNil(try mappedReset(offsetFromFullPeriod: -OpenCodeUsageMapper.placeholderResetTolerance - 0.5))
        XCTAssertNotNil(try mappedReset(offsetFromFullPeriod: OpenCodeUsageMapper.placeholderResetTolerance + 0.5))
        XCTAssertNotNil(try mappedReset(offsetFromFullPeriod: 5 * 60), "an implausibly distant reset is not a placeholder")
    }

    func testHTTPDateHeaderWinsOverSkewedLocalClock() throws {
        let serverDate = OpenUsageISO8601.date(from: "2027-01-15T08:00:00.000Z")!
        let placeholder = serverDate.addingTimeInterval(5 * 3600 + 0.5)
        let body: [String: Any] = [
            "usage": [
                "rolling": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: placeholder)],
                "weekly": ["percent": 0, "resetsAt": "2027-01-18T00:00:00.000Z"],
                "monthly": ["percent": 0, "resetsAt": "2027-02-10T08:00:00.000Z"]
            ]
        ]
        let response = HTTPResponse(
            statusCode: 200,
            headers: ["date": "Fri, 15 Jan 2027 08:00:00 GMT"],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let lines = try OpenCodeUsageMapper.meterLines(
            response,
            capturedAt: serverDate.addingTimeInterval(2 * 60) // deliberately wrong local clock
        )
        guard case let .progress(_, _, _, _, resetsAt, _, _) = lines[0] else {
            return XCTFail("session is not a progress line")
        }
        XCTAssertNil(resetsAt)
    }

    func testMissingOrMalformedHTTPDateFallsBackToCapturedAt() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let placeholder = capturedAt.addingTimeInterval(5 * 3600 + 0.5)
        let body: [String: Any] = [
            "usage": [
                "rolling": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: placeholder)],
                "weekly": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: capturedAt.addingTimeInterval(3 * 86_400))],
                "monthly": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: capturedAt.addingTimeInterval(20 * 86_400))]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        for headers in [[:], ["date": "not-an-http-date"]] {
            let response = HTTPResponse(statusCode: 200, headers: headers, body: data)
            let lines = try OpenCodeUsageMapper.meterLines(response, capturedAt: capturedAt)
            guard case let .progress(_, _, _, _, resetsAt, _, _) = lines[0] else {
                return XCTFail("session is not a progress line")
            }
            XCTAssertNil(resetsAt)
        }
    }

    /// Weekly and monthly resets are calendar/billing instants that exist with or without usage, so the
    /// placeholder rule must not touch them — early in a cycle one sits a near-full period out, and
    /// dropping it would strip a real countdown off a row that has no "Not started" state to fall to.
    func testFullPeriodWeeklyAndMonthlyResetsSurviveAtZeroUsage() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklyReset = capturedAt.addingTimeInterval(7 * 86_400)
        let monthlyReset = capturedAt.addingTimeInterval(30 * 86_400)
        let body: [String: Any] = [
            "usage": [
                "rolling": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: capturedAt.addingTimeInterval(2 * 3600))],
                "weekly": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: weeklyReset)],
                "monthly": ["percent": 0, "resetsAt": OpenUsageISO8601.string(from: monthlyReset)]
            ]
        ]
        let lines = try OpenCodeUsageMapper.meterLines(body: body, capturedAt: capturedAt)
        guard case let .progress(_, _, _, _, weekly, _, _) = lines[1],
              case let .progress(_, _, _, _, monthly, _, _) = lines[2] else {
            return XCTFail("expected progress lines")
        }
        XCTAssertEqual(weekly, weeklyReset)
        XCTAssertEqual(monthly, monthlyReset)
    }

    func testMissingOrMalformedResetIsInvalid() {
        let missingWeekly: [String: Any] = [
            "usage": [
                "rolling": ["percent": 0, "resetsAt": "2027-01-15T13:00:00.000Z"],
                "weekly": ["percent": 0],
                "monthly": ["percent": 0, "resetsAt": "2027-02-10T08:00:00.000Z"]
            ]
        ]
        let malformedRolling: [String: Any] = [
            "usage": [
                "rolling": ["percent": 0, "resetsAt": "not-a-date"],
                "weekly": ["percent": 0, "resetsAt": "2027-01-18T00:00:00.000Z"],
                "monthly": ["percent": 0, "resetsAt": "2027-02-10T08:00:00.000Z"]
            ]
        ]
        for body in [missingWeekly, malformedRolling] {
            XCTAssertThrowsError(try OpenCodeUsageMapper.meterLines(body: body)) { error in
                XCTAssertEqual(error as? OpenCodeUsageError, .invalidResponse)
            }
        }
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

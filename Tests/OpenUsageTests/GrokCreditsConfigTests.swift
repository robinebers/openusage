import XCTest
@testable import OpenUsage

final class GrokCreditsConfigDecoderTests: XCTestCase {
    func testDecodesLiveCapturedResponse() throws {
        let config = try GrokCreditsConfigDecoder.decode(responseBody: GrokCreditsFixtures.capturedResponseBody)

        XCTAssertEqual(config.periodType, GrokCreditsConfigDecoder.weeklyPeriodType)
        XCTAssertEqual(config.usedPercent, 99.0)
        XCTAssertEqual(config.periodStart.timeIntervalSince1970,
                       GrokCreditsFixtures.capturedPeriodStart.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(config.periodEnd.timeIntervalSince1970,
                       GrokCreditsFixtures.capturedPeriodEnd.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(config.periodDurationMs, 7 * 24 * 60 * 60 * 1000)
    }

    func testAbsentZeroValuedFieldsDecodeAsZero() throws {
        // proto-JSON drops zero-valued fields: a fresh weekly period omits `creditUsagePercent`
        // and a disabled cap omits `onDemandCap`. Those are genuine zeros, never schema errors.
        let noPercent = try GrokCreditsConfigDecoder.decode(
            responseBody: GrokCreditsFixtures.responseBody(percent: nil)
        )
        XCTAssertEqual(noPercent.usedPercent, 0)

        let noCap = try GrokCreditsConfigDecoder.decode(
            responseBody: GrokCreditsFixtures.responseBody(onDemandCap: nil)
        )
        XCTAssertEqual(noCap.onDemandCap, 0)
    }

    func testRejectsNonNumericFields() {
        // A present but non-numeric value is a schema change, not a 0 — clamping it to a
        // believable "0" would hide the drift.
        for body in [
            GrokCreditsFixtures.responseBody(percent: "high"),
            GrokCreditsFixtures.responseBody(onDemandCap: "lots")
        ] {
            XCTAssertThrowsError(try GrokCreditsConfigDecoder.decode(responseBody: body)) { error in
                XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
            }
        }
    }

    func testRejectsPeriodThatDoesNotMoveForward() {
        XCTAssertThrowsError(
            try GrokCreditsConfigDecoder.decode(responseBody: GrokCreditsFixtures.responseBody(
                start: "2026-07-07T21:36:52.140114+00:00", end: "2026-06-30T21:36:52.140114+00:00"
            ))
        ) { error in
            XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
        }
    }

    func testRejectsMissingConfigFields() {
        // A well-formed JSON body lacking the fields we map is a schema change, not a blank.
        for body in ["{}", #"{"config":{}}"#, #"{"config":{"currentPeriod":{}}}"#, "not json"] {
            XCTAssertThrowsError(
                try GrokCreditsConfigDecoder.decode(responseBody: Data(body.utf8)),
                "body: \(body)"
            ) { error in
                XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
            }
        }
    }
}

final class GrokCreditsConfigMapperTests: XCTestCase {
    func testMapsWeeklyLineAndBadgeFromCapturedResponse() throws {
        let mapped = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody
        ))

        guard case .progress(let label, let used, let limit, let format, let resetsAt, let periodDurationMs, _)? =
                mapped.lines.first(where: { $0.label == "Weekly limit" }) else {
            return XCTFail("expected a Weekly limit progress line, got \(mapped.lines)")
        }
        XCTAssertEqual(label, "Weekly limit")
        XCTAssertEqual(used, 99.0)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        XCTAssertEqual(resetsAt?.timeIntervalSince1970 ?? 0,
                       GrokCreditsFixtures.capturedPeriodEnd.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(periodDurationMs, 7 * 24 * 60 * 60 * 1000)

        guard case .badge(_, let text, let colorHex, _)? =
                mapped.lines.first(where: { $0.label == "Pay as you go" }) else {
            return XCTFail("expected a Pay as you go badge")
        }
        XCTAssertEqual(text, "Disabled", "captured cap is 0")
        XCTAssertEqual(colorHex, "#a3a3a3")
    }

    func testMapsEnabledPayAsYouGoCap() throws {
        let mapped = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.responseBody(onDemandCap: 2500)
        ))
        guard case .badge(_, let text, let colorHex, _)? =
                mapped.lines.first(where: { $0.label == "Pay as you go" }) else {
            return XCTFail("expected a Pay as you go badge")
        }
        XCTAssertEqual(text, "2500 cap")
        XCTAssertEqual(colorHex, "#22c55e")
    }

    // The non-weekly (monthly) period shape is covered end-to-end by
    // GrokProviderTests.testNonWeeklyPeriodShowsNoWeeklyLineAndNoWarning.

    func testClampsOutOfRangePercent() throws {
        let mapped = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.responseBody(percent: 150)
        ))
        guard case .progress(_, let used, _, _, _, _, _)? =
                mapped.lines.first(where: { $0.label == "Weekly limit" }) else {
            return XCTFail("expected a progress line")
        }
        XCTAssertEqual(used, 100)
    }

    func testAuthStatusesThrowAuthExpired() {
        for status in [401, 403] {
            XCTAssertThrowsError(try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
                statusCode: status, headers: [:], body: Data()
            ))) { error in
                XCTAssertEqual(error as? GrokAuthError, .expired, "HTTP \(status)")
            }
        }
    }

    func testOtherHTTPFailuresThrowRequestFailed() {
        XCTAssertThrowsError(try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 503, headers: [:], body: Data()
        ))) { error in
            XCTAssertEqual(error as? GrokUsageError, .requestFailed(503))
        }
    }
}

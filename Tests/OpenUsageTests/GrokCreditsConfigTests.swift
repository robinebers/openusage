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

    func testRejectsNonZeroGRPCStatus() {
        // The server reports errors inside an HTTP 200 via the trailer; a non-zero status must never
        // fall through to a parse of nothing.
        XCTAssertThrowsError(
            try GrokCreditsConfigDecoder.decode(responseBody: GrokCreditsFixtures.errorResponseBody(status: 13))
        ) { error in
            XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
        }
    }

    func testRejectsNonFinitePercent() {
        // clampPercent would silently turn NaN into 0, rendering a corrupt payload as a believable
        // "0% used" — the decoder must throw before any clamping.
        XCTAssertThrowsError(
            try GrokCreditsConfigDecoder.decode(responseBody: GrokCreditsFixtures.responseBody(percent: .nan))
        ) { error in
            XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
        }
        XCTAssertThrowsError(
            try GrokCreditsConfigDecoder.decode(responseBody: GrokCreditsFixtures.responseBody(percent: .infinity))
        ) { error in
            XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
        }
    }

    func testRejectsPeriodThatDoesNotMoveForward() {
        XCTAssertThrowsError(
            try GrokCreditsConfigDecoder.decode(responseBody: GrokCreditsFixtures.responseBody(
                startSeconds: 1_783_460_212, endSeconds: 1_782_855_412
            ))
        ) { error in
            XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
        }
    }

    func testRejectsMissingConfigFields() {
        // A well-formed frame whose protobuf lacks the fields we map is a schema change, not a blank.
        let empty = GRPCWebCodec.frame(Data()) + GrokCreditsFixtures.okTrailerFrame
        XCTAssertThrowsError(try GrokCreditsConfigDecoder.decode(responseBody: empty)) { error in
            XCTAssertEqual(error as? GrokUsageError, .invalidResponse)
        }
    }

    func testSkipsUnknownFieldsAroundTheOnesWeMap() throws {
        // Splice unknown fields (including a fixed64, a wire type the real capture doesn't use) around
        // the known ones at both nesting levels.
        let period = GrokCreditsFixtures.field(9, fixed64: 0xFEED)
            + GrokCreditsFixtures.field(1, varint: 2)
            + GrokCreditsFixtures.field(2, message: GrokCreditsFixtures.timestamp(seconds: 1_782_855_412))
            + GrokCreditsFixtures.field(3, message: GrokCreditsFixtures.timestamp(seconds: 1_783_460_212))
        let config = GrokCreditsFixtures.field(42, fixed64: 1)
            + GrokCreditsFixtures.field(1, float: 55.5)
            + GrokCreditsFixtures.field(8, message: period)
            + GrokCreditsFixtures.field(13, varint: 1)
        let body = GRPCWebCodec.frame(GrokCreditsFixtures.field(1, message: config)) + GrokCreditsFixtures.okTrailerFrame

        let decoded = try GrokCreditsConfigDecoder.decode(responseBody: body)

        XCTAssertEqual(decoded.usedPercent, 55.5)
        XCTAssertEqual(decoded.periodType, 2)
    }
}

final class GrokCreditsConfigMapperTests: XCTestCase {
    func testMapsWeeklyLineFromCapturedResponse() throws {
        let line = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody
        ))

        guard case .progress(let label, let used, let limit, let format, let resetsAt, let periodDurationMs, _)? = line else {
            return XCTFail("expected a progress line, got \(String(describing: line))")
        }
        XCTAssertEqual(label, "Weekly limit")
        XCTAssertEqual(used, 99.0)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        XCTAssertEqual(resetsAt?.timeIntervalSince1970 ?? 0,
                       GrokCreditsFixtures.capturedPeriodEnd.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(periodDurationMs, 7 * 24 * 60 * 60 * 1000)
    }

    func testNonWeeklyPeriodMapsToNoLine() throws {
        // An account still on monthly-only billing has no weekly pool; the tile must read "No data"
        // rather than mislabel a monthly percent as weekly.
        let line = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.responseBody(periodType: 1)
        ))
        XCTAssertNil(line)
    }

    func testClampsOutOfRangePercent() throws {
        let line = try GrokUsageMapper.mapCreditsConfig(HTTPResponse(
            statusCode: 200, headers: [:], body: GrokCreditsFixtures.responseBody(percent: 150)
        ))
        guard case .progress(_, let used, _, _, _, _, _)? = line else {
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

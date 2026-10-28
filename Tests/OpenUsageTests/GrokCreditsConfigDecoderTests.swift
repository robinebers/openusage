import XCTest
@testable import OpenUsage

/// Grok's credits config is proto-JSON, so a zero-valued field is omitted rather than written; the
/// decoder reads an absent percent or cap as 0 and a present but malformed one, a period that does
/// not move forward, or a body without the config as `ProviderError.invalidResponse`.
final class GrokCreditsConfigDecoderTests: XCTestCase {
    func testAbsentZeroValuedFieldsDecodeAsZero() throws {
        XCTAssertEqual(try GrokCreditsConfigDecoder.decode(responseBody: Self.responseBody(percent: nil)).usedPercent, 0)
        XCTAssertEqual(try GrokCreditsConfigDecoder.decode(responseBody: Self.responseBody(onDemandCap: nil)).onDemandCap, 0)
    }

    func testRejectsNonNumericFields() {
        for body in [Self.responseBody(percent: "high"), Self.responseBody(onDemandCap: "lots")] {
            XCTAssertThrowsError(try GrokCreditsConfigDecoder.decode(responseBody: body)) { error in
                XCTAssertEqual(error as? ProviderError, .invalidResponse)
            }
        }
    }

    func testRejectsPeriodThatDoesNotMoveForward() {
        let reversed = Self.responseBody(start: "2026-07-07T21:36:52.140114+00:00", end: "2026-06-30T21:36:52.140114+00:00")
        XCTAssertThrowsError(try GrokCreditsConfigDecoder.decode(responseBody: reversed)) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }

    func testRejectsMissingConfigFields() {
        for body in ["{}", #"{"config":{}}"#, #"{"config":{"currentPeriod":{}}}"#, "not json"] {
            XCTAssertThrowsError(try GrokCreditsConfigDecoder.decode(responseBody: Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ProviderError, .invalidResponse)
            }
        }
    }

    private static func responseBody(
        percent: Any? = 99.0,
        onDemandCap: Any? = 2500,
        start: String = "2026-06-30T21:36:52.140114+00:00",
        end: String = "2026-07-07T21:36:52.140114+00:00"
    ) -> Data {
        var config: [String: Any] = ["currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "start": start, "end": end]]
        if let percent { config["creditUsagePercent"] = percent }
        if let onDemandCap { config["onDemandCap"] = ["val": onDemandCap] }
        return try! JSONSerialization.data(withJSONObject: ["config": config])
    }
}

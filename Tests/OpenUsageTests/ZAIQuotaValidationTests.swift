import XCTest
@testable import OpenUsage

final class ZAIQuotaValidationMapperTests: XCTestCase {
    func testMissingRequiredValuesNeverBecomeZeroUsage() {
        let malformedLimits = [
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}"#,
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":true}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","usage":1000}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":10}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":-1,"usage":1000}]}}"#
        ]

        for body in malformedLimits {
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ProviderError, .invalidResponse, body)
            }
        }
    }

    func testMalformedEnvelopeIsRejectedButExplicitEmptyLimitsRemainValid() throws {
        for body in ["not-json", #"{"data":[]}"#, #"{"data":{}}"#, #"{"data":{"limits":{}}}"#] {
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ProviderError, .invalidResponse, body)
            }
        }

        let lines = try ZAIUsageMapper.mapQuota(Data(#"{"data":{"limits":[]}}"#.utf8))
        XCTAssertTrue(lines.isEmpty)
    }

    func testUnknownEntriesDoNotHideKnownMeters() throws {
        let body = Data(
            #"{"data":{"limits":[{"type":"FUTURE_LIMIT"},{"type":"TOKENS_LIMIT","unit":99,"number":1,"percentage":70},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}]}}"#.utf8
        )

        let lines = try ZAIUsageMapper.mapQuota(body)

        XCTAssertNotNil(lines.first { $0.label == "Session" })
        XCTAssertNil(lines.first { $0.label == "Weekly" })
    }

    func testOnlyUnknownLimitsRemainForwardCompatibleNoData() throws {
        let body = Data(
            #"{"data":{"limits":[{"type":"FUTURE_LIMIT"},{"type":"TOKENS_LIMIT","unit":99,"number":1,"percentage":70}]}}"#.utf8
        )

        let lines = try ZAIUsageMapper.mapQuota(body)

        XCTAssertTrue(lines.isEmpty)
    }
}

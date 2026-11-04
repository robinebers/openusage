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

    func testAKeyWithNoCodingPlanSaysSoAndAnyOtherFailedBodyStaysInvalid() {
        let noPlan = Data(#"{"code":500,"msg":"当前用户不存在coding plan","success":false}"#.utf8)
        XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(noPlan)) { error in
            XCTAssertEqual(error as? ProviderError, .unavailable("No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage."))
        }

        let other = Data(#"{"code":500,"msg":"internal error","success":false}"#.utf8)
        XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(other)) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }

    func testAKeyZaiRefusesInsideAnOKResponseIsRejected() {
        let refused = Data(#"{"code":401,"msg":"token expired or incorrect","success":false}"#.utf8)
        XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(refused)) { error in
            XCTAssertEqual(error as? ProviderError, .signInExpired(.zai))
        }
    }

    func testUnknownLimitsShowNothingAndDoNotHideKnownMeters() throws {
        let unknown = #"{"type":"FUTURE_LIMIT"},{"type":"TOKENS_LIMIT","unit":99,"number":1,"percentage":70}"#
        XCTAssertTrue(try ZAIUsageMapper.mapQuota(Data(#"{"data":{"limits":[\#(unknown)]}}"#.utf8)).isEmpty)

        let known = #"{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}"#
        let lines = try ZAIUsageMapper.mapQuota(Data(#"{"data":{"limits":[\#(unknown),\#(known)]}}"#.utf8))

        XCTAssertNotNil(lines.first { $0.label == "Session" })
        XCTAssertNil(lines.first { $0.label == "Weekly" })
    }
}

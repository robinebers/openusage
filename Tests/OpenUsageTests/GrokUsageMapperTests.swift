import XCTest
@testable import OpenUsage

final class GrokUsageMapperTests: XCTestCase {
    func testATeamPrincipalsRefusalIsANoticeWithNoRowsAndAnyOther412IsARequestFailure() throws {
        let team = HTTPResponse(statusCode: 412, headers: [:], body: Data(#"{"error":"principal has no personal team"}"#.utf8))
        XCTAssertEqual(try GrokUsageMapper.mapCreditsConfig(team),
                       ProviderUsage(lines: [], notice: "Grok team accounts have no personal quota."))

        let other = HTTPResponse(statusCode: 412, headers: [:], body: Data(#"{"error":"precondition failed"}"#.utf8))
        XCTAssertThrowsError(try GrokUsageMapper.mapCreditsConfig(other)) { error in
            XCTAssertEqual(error as? ProviderError, .requestFailed(412))
        }
    }

    func testAPayAsYouGoCapTooLargeForAnIntIsAnInvalidResponse() {
        let body = #"""
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-30T21:36:52Z",
         "end":"2026-07-07T21:36:52Z"},"onDemandCap":{"val":1e300}}}
        """#
        XCTAssertThrowsError(try GrokUsageMapper.mapCreditsConfig(HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)))) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }
}

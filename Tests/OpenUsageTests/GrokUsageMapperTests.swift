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
}

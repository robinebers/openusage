import XCTest
@testable import OpenUsage

final class GrokUsageMapperTests: XCTestCase {
    func testATeamPrincipalsRefusalNamesTheAccountShapeAndAnyOther412IsARequestFailure() {
        let team = HTTPResponse(statusCode: 412, headers: [:], body: Data(#"{"error":"principal has no personal team"}"#.utf8))
        XCTAssertThrowsError(try GrokUsageMapper.mapCreditsConfig(team)) { error in
            XCTAssertEqual(error as? ProviderError, .unavailable("Grok team accounts have no personal quota."))
        }

        let other = HTTPResponse(statusCode: 412, headers: [:], body: Data(#"{"error":"precondition failed"}"#.utf8))
        XCTAssertThrowsError(try GrokUsageMapper.mapCreditsConfig(other)) { error in
            XCTAssertEqual(error as? ProviderError, .requestFailed(412))
        }
    }
}

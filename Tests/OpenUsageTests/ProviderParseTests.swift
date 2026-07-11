import XCTest
@testable import OpenUsage

final class ProviderParseTests: XCTestCase {
    func testURLFormEncodingPreservesOnlyRFC3986UnreservedASCII() {
        XCTAssertEqual("AZaz09-._~".urlFormEncoded, "AZaz09-._~")
        XCTAssertEqual(
            "space & equals= plus+ slash/ question? percent%".urlFormEncoded,
            "space%20%26%20equals%3D%20plus%2B%20slash%2F%20question%3F%20percent%25"
        )
        XCTAssertEqual("café".urlFormEncoded, "caf%C3%A9")
    }
}

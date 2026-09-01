import XCTest
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testProviderVectorMarksLoadWithoutFallbacks() throws {
        for id in ["claude", "codex", "cursor", "devin", "grok"] {
            let mark = try XCTUnwrap(ProviderMarks.mark(for: id), "\(id) should load a vector mark")
            XCTAssertFalse(mark.path.isEmpty, "\(id) mark must carry SVG path data")
        }
    }
}

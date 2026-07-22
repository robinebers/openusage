import XCTest
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testGrokResolvesToVectorMarkNotBoltFallback() {
        let mark = ProviderMarks.mark(for: "grok")
        XCTAssertNotNil(mark, "Grok must load a real vector mark instead of the bolt.fill fallback")
        XCTAssertFalse(mark?.path.isEmpty ?? true, "Grok mark must carry SVG path data")
    }

    func testDevinResolvesToVectorMark() {
        let mark = ProviderMarks.mark(for: "devin")
        XCTAssertNotNil(mark)
        XCTAssertFalse(mark?.path.isEmpty ?? true, "Devin mark must carry SVG path data")
    }

    func testStandardProviderMarksLoad() {
        for id in ["claude", "codex", "commandcode", "cursor"] {
            let mark = ProviderMarks.mark(for: id)
            XCTAssertNotNil(mark, "\(id) should load")
            XCTAssertFalse(mark?.path.isEmpty ?? true, "\(id) mark must carry SVG path data")
        }
    }
}

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
        for id in ["claude", "codex", "cursor"] {
            let mark = ProviderMarks.mark(for: id)
            XCTAssertNotNil(mark, "\(id) should load")
            XCTAssertFalse(mark?.path.isEmpty ?? true, "\(id) mark must carry SVG path data")
        }
    }

    /// Kimi's mark is hand-authored from lines and cubics because `SVGPath` has no arc support, so this
    /// pins that it still parses into real geometry rather than silently degrading to the SF Symbol
    /// fallback or an empty shape.
    func testKimiResolvesToVectorMarkWithRenderableGeometry() throws {
        let mark = try XCTUnwrap(
            ProviderMarks.mark(for: "kimi"),
            "Kimi must load a real vector mark instead of the moon.stars fallback"
        )
        XCTAssertFalse(mark.path.isEmpty)

        let bounds = ProviderIconShape(pathData: mark.path)
            .path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
            .boundingRect
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
    }
}

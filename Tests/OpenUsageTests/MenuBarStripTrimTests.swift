import XCTest
@testable import OpenUsage

/// Covers the Text strip's transparent-margin trim: `visibleBounds(of:)` finds the opaque pixel box in
/// `CGImage.cropping(to:)`'s coordinate space (top-left origin — an off-center mark pins the
/// orientation), and `image(for:)` ships with zero transparent margins so the status item hugs its
/// artwork and the menu bar's own padding is the only gap next to neighboring items.
@MainActor
final class MenuBarStripTrimTests: XCTestCase {
    func testVisibleBoundsFindsOffCenterContent() throws {
        let image = try makeImage(width: 20, height: 10, opaqueRect: CGRect(x: 4, y: 1, width: 3, height: 2))

        let bounds = try XCTUnwrap(MenuBarStripRenderer.visibleBounds(of: image))
        XCTAssertEqual(bounds, CGRect(x: 4, y: 1, width: 3, height: 2))

        let trimmed = try XCTUnwrap(MenuBarStripRenderer.trimmedToVisibleContent(image))
        XCTAssertEqual(MenuBarStripRenderer.visibleBounds(of: trimmed), CGRect(x: 0, y: 0, width: 3, height: 2))
    }

    func testVisibleBoundsNilForFullyTransparentImage() throws {
        let image = try makeImage(width: 8, height: 8, opaqueRect: nil)
        XCTAssertNil(MenuBarStripRenderer.visibleBounds(of: image))
        XCTAssertNil(MenuBarStripRenderer.trimmedToVisibleContent(image))
    }

    func testTextImageHasNoTransparentMargins() throws {
        let content = MenuBarContent(items: [
            item("claude.session", "Session", "99%"),
            item("claude.weekly", "Weekly", "87%"),
        ])

        let image = try XCTUnwrap(MenuBarStripRenderer.image(for: content))
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bounds = try XCTUnwrap(MenuBarStripRenderer.visibleBounds(of: cgImage))

        XCTAssertEqual(bounds, CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, content.accessibilityText)
    }

    func testTheStripFitsTheMenuBarWithABadgeADescenderAndTheOverflow() throws {
        let plain = MenuBarContent(items: [item("claude.weekly", "Weekly", "99%")])
        let badged = MenuBarContent(items: [
            item("claude@1.weekly", "Weekly", "99%", badge: "A1"),
            item("claude@2.spring", "Spring", "$12K", badge: "P"),
        ], overflow: 12)

        for content in [plain, badged] {
            let image = try XCTUnwrap(MenuBarStripRenderer.image(for: content))
            XCTAssertLessThanOrEqual(image.size.height, Self.menuBarHeight, content.accessibilityText)
        }
    }

    func testTheItemsAndTheOverflowEachWidenTheStrip() throws {
        let one = MenuBarContent(items: [item("claude.session", "Session", "99%")])
        let two = MenuBarContent(items: [item("claude.session", "Session", "99%"), item("claude.weekly", "Weekly", "87%")])
        var more = two
        more.overflow = 7

        let widths = try [one, two, more].map { try XCTUnwrap(MenuBarStripRenderer.image(for: $0)).size.width }
        XCTAssertGreaterThan(widths[1], widths[0] * 1.5, "two limits of one account drew one item")
        XCTAssertGreaterThan(widths[2], widths[1] + 11, "the overflow drew nothing")
    }

    /// The system menu bar, with the room it leaves on a Mac without a notch.
    private static let menuBarHeight: CGFloat = 22

    private func item(_ id: String, _ label: String, _ value: String, badge: String? = nil) -> MenuBarContent.Item {
        MenuBarContent.Item(
            id: id,
            provider: Provider(id: String(id.prefix { $0 != "." }), kind: .claude, badge: badge),
            label: label,
            shortLabel: label,
            value: value
        )
    }

    /// Draws an optional opaque rect (given in top-left-origin pixel coordinates) on a transparent
    /// canvas. The fill converts to the context's bottom-left-origin user space, so the produced
    /// `CGImage` has the block exactly where the test expects it.
    private func makeImage(width: Int, height: Int, opaqueRect: CGRect?) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        if let rect = opaqueRect {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        return try XCTUnwrap(context.makeImage())
    }
}

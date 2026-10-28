import XCTest
@testable import OpenUsage

/// Covers the Text strip's transparent-margin trim: `visibleBounds(of:)` finds the opaque pixel box in
/// `CGImage.cropping(to:)`'s coordinate space (top-left origin — an off-center mark pins the
/// orientation), and `image(for:)` ships with zero transparent margins so the status item hugs its
/// artwork and the menu bar's own padding is the only gap next to neighboring items.
@MainActor
final class MenuBarStripTrimTests: XCTestCase {
    func testVisibleBoundsFindsOffCenterContent() throws {
        // A 3x2 opaque block near the top-left of a 20x10 canvas: rows 1...2 from the top, columns
        // 4...6. If the scan or the crop were vertically flipped, the trim would land on empty pixels.
        let image = try makeImage(width: 20, height: 10, opaqueRect: CGRect(x: 4, y: 1, width: 3, height: 2))

        let bounds = try XCTUnwrap(MenuBarStripRenderer.visibleBounds(of: image))
        XCTAssertEqual(bounds, CGRect(x: 4, y: 1, width: 3, height: 2))

        let trimmed = try XCTUnwrap(MenuBarStripRenderer.trimmedToVisibleContent(image))
        XCTAssertEqual(trimmed.width, 3)
        XCTAssertEqual(trimmed.height, 2)
        XCTAssertEqual(MenuBarStripRenderer.visibleBounds(of: trimmed), CGRect(x: 0, y: 0, width: 3, height: 2))
    }

    func testVisibleBoundsNilForFullyTransparentImage() throws {
        let image = try makeImage(width: 8, height: 8, opaqueRect: nil)
        XCTAssertNil(MenuBarStripRenderer.visibleBounds(of: image))
        XCTAssertNil(MenuBarStripRenderer.trimmedToVisibleContent(image))
    }

    func testTextImageHasNoTransparentMargins() throws {
        let content = MenuBarContent(
            groups: [
                MenuBarContent.Group(
                    providerID: "claude",
                    displayName: "Claude",
                    icon: "claude",
                    metrics: [
                        MenuBarContent.Metric(id: "claude.session", label: "Session", value: "99%",
                                              hasData: true),
                        MenuBarContent.Metric(id: "claude.weekly", label: "Weekly", value: "87%",
                                              hasData: true)
                    ]
                )
            ]
        )

        let image = try XCTUnwrap(MenuBarStripRenderer.image(for: content))
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bounds = try XCTUnwrap(MenuBarStripRenderer.visibleBounds(of: cgImage))

        XCTAssertEqual(bounds, CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, content.accessibilityText)
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

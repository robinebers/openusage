import XCTest
import SwiftUI
@testable import OpenUsage

/// Covers the Share card export pipeline: `image(for:)` rasterizes the flexible-height card, and
/// `pngData(from:)` round-trips to a valid PNG. `ImageRenderer` is MainActor-only, so the whole case
/// runs on the main actor. Pixel dimensions are checked scale-agnostically (the bitmap width is a
/// multiple of the authored card width) because `ImageRenderer.scale` is not honored in headless CI.
@MainActor
final class ShareCardRendererTests: XCTestCase {
    private func sampleCard() -> ShareCardView {
        let provider = MockData.claude
        let rows = MockData.descriptors(for: provider.id).map { $0.sample }
        return ShareCardView(provider: provider, plan: "Max", rows: rows, appearance: .light)
    }

    func testImageRasterizesAtAuthoredWidthMultiple() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))

        // The bitmap width is the authored card width times the render scale. `ImageRenderer.scale` is
        // not honored in headless CI (it rasterizes at ×1), so assert a scale-agnostic multiple rather
        // than an exact `width * scale` — it holds at ×1 in CI and ×4 locally.
        let rep = try XCTUnwrap(image.representations.first)
        let width = Int(ShareCardView.width)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        XCTAssertEqual(rep.pixelsWide % width, 0, "bitmap width should be a whole multiple of the authored card width")
        XCTAssertGreaterThan(rep.pixelsHigh, 0, "flexible-height card should rasterize with a positive height")
    }

    func testPNGDataRoundTripsToValidPNG() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))
        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))

        XCTAssertFalse(png.isEmpty)
        // PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A.
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(png.prefix(magic.count)), magic)
        // The PNG must decode back into an image (a non-empty Data alone isn't proof it's valid).
        XCTAssertNotNil(NSImage(data: png))
    }

    func testRendersEmptyProviderWithoutCrashing() throws {
        let card = ShareCardView(provider: MockData.cursor, plan: nil, rows: [], appearance: .dark)
        let image = try XCTUnwrap(ShareCardRenderer.image(for: card))
        let rep = try XCTUnwrap(image.representations.first)
        // Same scale-agnostic width check; the point is it doesn't crash on an empty provider.
        XCTAssertEqual(rep.pixelsWide % Int(ShareCardView.width), 0)
        XCTAssertGreaterThan(rep.pixelsHigh, 0)
    }

    func testCondensedTextRowIndicesFollowsNeighborRule() {
        let rows = MockData.descriptors(for: MockData.claude.id).map { $0.sample }
        XCTAssertGreaterThan(rows.count, 1, "sample fixture should have multiple rows")
        let condensed = ShareCardView.condensedTextRowIndices(rows)
        XCTAssertFalse(condensed.contains(0), "the first row is never condensed")
        for i in 1..<rows.count {
            let expected = !rows[i - 1].isBounded && !rows[i].isBounded
            XCTAssertEqual(condensed.contains(i), expected,
                           "row \(i) condensing should match the neighbor-aware text-only rule")
        }
    }

    func testCondensedTextRowIndicesRespectExpandBoundary() {
        let rows = MockData.descriptors(for: MockData.claude.id).map { $0.sample }
        XCTAssertGreaterThan(rows.count, 1, "sample fixture should have multiple rows")
        let boundary = rows.count / 2
        let condensed = ShareCardView.condensedTextRowIndices(rows, boundary: boundary)
        XCTAssertFalse(condensed.contains(boundary), "the first expanded row (at the boundary) is never condensed")
        for i in 1..<rows.count {
            let sameSide = (i < boundary) == (i - 1 < boundary)
            let expected = sameSide && !rows[i - 1].isBounded && !rows[i].isBounded
            XCTAssertEqual(condensed.contains(i), expected,
                           "row \(i) condensing should not bridge the expand caret boundary")
        }
    }
}

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

    /// The neighbor-aware condensing rule on a fixed fixture: a text-only row condenses only under
    /// another text-only row, and the expand caret is a hard boundary a run never bridges.
    func testCondensedTextRowIndicesFollowNeighborRuleAndRespectExpandBoundary() {
        func row(bounded: Bool) -> WidgetData {
            WidgetData(title: "Row", icon: .providerMark("claude"), kind: .percent, used: 0, limit: bounded ? 100 : nil)
        }
        // Meter, then a run of three text-only rows.
        let rows = [row(bounded: true), row(bounded: false), row(bounded: false), row(bounded: false)]

        XCTAssertEqual(ShareCardView.condensedTextRowIndices(rows), [2, 3])
        // With the caret between rows 1 and 2, row 2 starts the expanded segment (never condensed);
        // only row 3 still condenses.
        XCTAssertEqual(ShareCardView.condensedTextRowIndices(rows, boundary: 2), [3])
    }

    // MARK: - Clipboard write result

    /// `copyToPasteboard` reports `false` when the image can't be PNG-encoded, so `share` can gate the
    /// "Copied to clipboard" confirmation on a real successful write instead of claiming success after a
    /// silent encode/pasteboard failure. Regression guard for the success-pill-after-copy-failure bug.
    func testCopyToPasteboardReturnsFalseForUnencodableImage() {
        // An empty NSImage has no representations, so tiffRepresentation is nil and PNG encoding fails.
        let empty = NSImage()
        XCTAssertFalse(ShareCardRenderer.copyToPasteboard(empty),
                       "a failed encode must report false, not silently return success")
    }

    /// `copyToPasteboard` reports `true` and actually writes PNG data onto the pasteboard for a valid
    /// image — the success contract the confirmation gates on.
    func testCopyToPasteboardWritesPNGAndReturnsTrueForValidImage() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))
        XCTAssertTrue(ShareCardRenderer.copyToPasteboard(image))

        let png = try XCTUnwrap(NSPasteboard.general.data(forType: .png))
        XCTAssertFalse(png.isEmpty)
        // PNG magic bytes confirm the pasteboard holds an actual PNG, not just non-empty data.
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(png.prefix(magic.count)), magic)
    }
}

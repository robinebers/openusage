import XCTest
import SwiftUI
@testable import OpenUsage

@MainActor
final class ShareCardRendererTests: XCTestCase {
    private func sampleCard() -> ShareCardView {
        let provider = MockData.claude
        let lines = MockData.descriptors(for: provider.id).map { DashboardLine(descriptor: $0, data: $0.sample) }
        let family = DashboardFamily(id: provider.id, provider: provider, accounts: [DashboardAccount(provider: provider, lines: lines)])
        return ShareCardView(family: family, plans: [provider.id: "Max"], appearance: .light)
    }

    func testImageRasterizesAtAuthoredWidthMultiple() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(ShareCardRenderer.png(for: sampleCard()))))

        // The bitmap width is the authored card width times the render scale. `ImageRenderer.scale` is
        // not honored in headless CI (it rasterizes at ×1), so assert a scale-agnostic multiple rather
        // than an exact `width * scale` — it holds at ×1 in CI and ×4 locally.
        let width = Int(ShareCardView.width)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        XCTAssertEqual(rep.pixelsWide % width, 0, "bitmap width should be a whole multiple of the authored card width")
        XCTAssertGreaterThan(rep.pixelsHigh, 0, "flexible-height card should rasterize with a positive height")
    }

    func testPNGDataRoundTripsToValidPNG() throws {
        let png = try XCTUnwrap(ShareCardRenderer.png(for: sampleCard()))

        XCTAssertFalse(png.isEmpty)
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(png.prefix(magic.count)), magic)
        XCTAssertNotNil(NSImage(data: png))
    }

    func testRendersEmptyProviderWithoutCrashing() throws {
        let empty = DashboardFamily(id: "cursor", provider: MockData.cursor, accounts: [DashboardAccount(provider: MockData.cursor, lines: [])])
        let card = ShareCardView(family: empty, appearance: .dark)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(ShareCardRenderer.png(for: card))))
        XCTAssertEqual(rep.pixelsWide % Int(ShareCardView.width), 0)
        XCTAssertGreaterThan(rep.pixelsHigh, 0)
    }
}

import AppKit
import XCTest
@testable import OpenUsage

@MainActor
final class ShareCardRendererTests: XCTestCase {
    func testProviderScreenshotRedactsEmailButIncludesACustomName() throws {
        func png(label: String?) throws -> Data {
            var provider = MockData.claude
            provider.accountLabel = label
            let lines = MockData.descriptors(for: provider.id).map { DashboardLine(descriptor: $0, data: $0.sample) }
            let account = DashboardAccount(provider: provider, lines: lines)
            let family = DashboardFamily(id: provider.id, provider: provider, accounts: [account])
            let card = ShareCardView(family: family, appearance: .light)
            return try XCTUnwrap(ShareCardRenderer.png(for: card))
        }

        let redacted = try png(label: "private@example.com")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: redacted))
        // Without a plan the caption exists only when the account's name is printed.
        let unnamed = try XCTUnwrap(NSBitmapImageRep(data: try png(label: nil)))
        let named = try XCTUnwrap(NSBitmapImageRep(data: try png(label: "Work")))
        XCTAssertEqual(bitmap.pixelsHigh, unnamed.pixelsHigh)
        XCTAssertGreaterThan(named.pixelsHigh, bitmap.pixelsHigh)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(ShareCardView.width))
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        XCTAssertTrue(redacted.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }
}

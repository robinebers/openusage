import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class ProviderHeaderLayoutTests: XCTestCase {
    private let longPlan = String(repeating: "Future Enterprise Entitlement ", count: 12)

    func testDashboardHeaderFitsOversizedPlanInBothDensities() throws {
        for density in DensitySetting.allCases {
            let suite = "ProviderHeaderLayoutTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(density.rawValue, forKey: DensitySetting.key)
            defer { defaults.removePersistentDomain(forName: suite) }

            let header = ProviderSectionHeader(
                provider: CodexProvider.makeProvider(),
                plan: longPlan,
                warning: "Refresh failed",
                staleness: StalenessHint(label: "Outdated", tooltip: "Last updated 2h ago"),
                onCopyScreenshot: { true }
            )
            .defaultAppStorage(defaults)
            .environment(\.hoverTooltipsDisabled, true)

            // 320pt popover minus 14pt outer and 8pt section padding on each side.
            try assertFits(header, width: 276)
        }
    }

    func testShareHeaderFitsOversizedPlan() throws {
        let card = ShareCardView(
            provider: CodexProvider.makeProvider(), plan: longPlan, rows: [], appearance: .light
        )
        // Test the header itself: the card's outer fixed frame would hide child overflow.
        try assertFits(card.headerRow, width: ShareCardView.width - 32)
    }

    private func assertFits<Content: View>(
        _ content: Content, width: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, file: file, line: line)
        XCTAssertLessThanOrEqual(image.width, Int(width), file: file, line: line)
        XCTAssertGreaterThan(image.height, 0, file: file, line: line)
    }
}

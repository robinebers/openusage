import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PanelScrollEdgeTests: QuietWindowTestCase {
    /// The panel's pages and Settings' form fade scrolled content out where it meets a bar, so the panel
    /// shows through there instead of the content or a system scroll edge effect.
    func testScrolledContentFadesOutUnderTheBar() async throws {
        let barHeight: CGFloat = 30
        let pages: [(String, AnyView)] = [
            ("page", AnyView(PopoverScrollView { Self.content })),
            ("form", AnyView(Form { Self.content }.formStyle(.grouped).panelScrollEdge())),
        ]
        for (name, page) in pages {
            let (_, host) = show(
                page
                    .safeAreaInset(edge: .top, spacing: 0) { Color.red.frame(height: barHeight) }
                    .background(Color.red),
                in: .borderless,
                size: CGSize(width: 200, height: 200)
            )
            let scroller = try XCTUnwrap(scrollViews(in: host).first)
            scroller.contentView.scroll(to: NSPoint(x: 0, y: scroller.contentView.bounds.minY + 100))
            scroller.reflectScrolledClipView(scroller.contentView)
            try await Task.sleep(for: .milliseconds(100))

            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            func color(_ y: CGFloat) -> NSColor {
                rep.colorAt(x: Int(host.bounds.midX * scale), y: Int(y * scale))!.usingColorSpace(.deviceRGB)!
            }
            let panel = color(barHeight / 2)
            XCTAssertGreaterThan(color(barHeight + 60).distance(to: panel), 0.5, "\(name): nothing scrolled under the bar")
            XCTAssertLessThan(color(barHeight).distance(to: panel), 0.1, "\(name): content shows at the bar's edge")
        }
    }

    private static var content: some View {
        Color.black.frame(height: 1_000)
    }
}

private extension NSColor {
    func distance(to other: NSColor) -> CGFloat {
        max(abs(redComponent - other.redComponent), abs(greenComponent - other.greenComponent), abs(blueComponent - other.blueComponent))
    }
}

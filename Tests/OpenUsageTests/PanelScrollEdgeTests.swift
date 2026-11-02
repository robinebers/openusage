import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PanelScrollEdgeTests: QuietWindowTestCase {
    /// The panel's pages and Settings' form frost a bar with an in-window blur once content scrolls under
    /// it, and draw nothing behind the bar while nothing is under it.
    func testABarFrostsOnlyWhileContentIsUnderIt() async throws {
        let barHeight: CGFloat = 30
        let pages: [(String, AnyView)] = [
            ("page", AnyView(PopoverScrollView { Self.content })),
            ("form", AnyView(Form { Self.content }.formStyle(.grouped).scrollContentBackground(.hidden))),
        ]
        for (name, page) in pages {
            let (_, host) = show(
                page.panelBars { Color.clear.frame(height: barHeight) } bottom: { Color.clear.frame(height: barHeight) },
                in: .borderless,
                size: CGSize(width: 200, height: 200)
            )
            try await Task.sleep(for: .milliseconds(100))
            let edges = [host.bounds.minY, host.bounds.maxY - barHeight]
            let topBar = NSRect(x: 0, y: host.isFlipped ? edges[0] : edges[1], width: host.bounds.width, height: barHeight)
            let bottomBar = NSRect(x: 0, y: host.isFlipped ? edges[1] : edges[0], width: host.bounds.width, height: barHeight)
            XCTAssertFalse(frosts(topBar, in: host), "\(name): the top bar frosts with nothing under it")
            XCTAssertTrue(frosts(bottomBar, in: host), "\(name): the bottom bar stays clear over content")

            let scroller = try XCTUnwrap(scrollViews(in: host).first)
            scroller.contentView.scroll(to: NSPoint(x: 0, y: scroller.contentView.bounds.minY + 100))
            scroller.reflectScrolledClipView(scroller.contentView)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(frosts(topBar, in: host), "\(name): the top bar stays clear over content")
        }
    }

    /// Whether an in-window blur shows over all of `bar`, a rect in `host`'s coordinates.
    private func frosts(_ bar: NSRect, in host: NSView) -> Bool {
        host.layoutSubtreeIfNeeded()
        return visualEffectViews(in: host).contains { blur in
            var opacity = blur.alphaValue
            var view: NSView? = blur.superview
            while let ancestor = view, ancestor !== host {
                opacity *= ancestor.alphaValue
                view = ancestor.superview
            }
            return !blur.isHiddenOrHasHiddenAncestor && opacity > 0.99 && blur.blendingMode == .withinWindow
                && blur.convert(blur.bounds, to: host).contains(bar)
        }
    }

    private func visualEffectViews(in view: NSView) -> [NSVisualEffectView] {
        [view as? NSVisualEffectView].compactMap { $0 } + view.subviews.flatMap(visualEffectViews)
    }

    private static var content: some View {
        Color.black.frame(height: 1_000)
    }
}

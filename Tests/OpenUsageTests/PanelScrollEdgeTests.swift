import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PanelScrollEdgeTests: QuietWindowTestCase {
    /// On the panel's pages and Settings' form, content scrolled under the top bar is hidden behind the
    /// panel, with no blur. Before macOS 27, content under the bottom bar frosts it with an in-window blur,
    /// and the bottom bar is clear once nothing is under it. (From macOS 27 the system draws that edge.)
    func testTheTopBarHidesContentAndTheBottomBarFrostsOverIt() async throws {
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
            let frostsBelow = { () -> Bool? in
                if #available(macOS 27, *) { return nil }
                return self.frosts(bottomBar, in: host)
            }
            XCTAssertNotEqual(frostsBelow(), false, "\(name): the bottom bar stays clear over content")

            let scroller = try XCTUnwrap(scrollViews(in: host).first)
            scroller.contentView.scroll(to: NSPoint(x: 0, y: scroller.contentView.bounds.minY + 100))
            scroller.reflectScrolledClipView(scroller.contentView)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(frosts(topBar, in: host), "\(name): the top bar frosts")
            XCTAssertFalse(try showsContent(in: topBar, of: host), "\(name): content shows through the top bar")

            scroller.contentView.scroll(to: NSPoint(x: 0, y: 10_000))
            scroller.reflectScrolledClipView(scroller.contentView)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNotEqual(frostsBelow(), true, "\(name): the bottom bar frosts with nothing under it")
        }
    }

    /// A tab switch draws its new rows a frame before the panel takes their height. In that frame the
    /// bottom bar covers them in the panel's color, so they don't flash through `Next update`; once the
    /// panel fits the page, the bar shows what is under it again (frosted before macOS 27).
    func testTheBottomBarCoversContentOnlyWhileThePanelIsAtAnotherHeight() async throws {
        let barHeight: CGFloat = 30
        MenuBarPopover.clampHeight = { min($0, 300) }
        addTeardownBlock { MenuBarPopover.clampHeight = nil }
        let (window, host) = show(
            PopoverScrollView { Color.blue.frame(height: 1_000) }
                .panelBars { Color.clear.frame(height: barHeight) } bottom: { Color.clear.frame(height: barHeight) },
            in: .borderless,
            size: CGSize(width: 200, height: 200)
        )
        try await Task.sleep(for: .milliseconds(100))
        let bottomBar = { NSRect(x: 0, y: host.isFlipped ? host.bounds.maxY - barHeight : 0, width: host.bounds.width, height: barHeight) }
        let isBlue = { (color: NSColor) in color.blueComponent - max(color.redComponent, color.greenComponent) > 0.2 }
        XCTAssertFalse(try showsContent(in: bottomBar(), of: host, matching: isBlue), "content shows through the bottom bar before the panel fits it")

        window.setContentSize(CGSize(width: 200, height: 300))
        try await Task.sleep(for: .milliseconds(100))
        if #available(macOS 27, *) {
            XCTAssertTrue(try showsContent(in: bottomBar(), of: host, matching: isBlue), "the bottom bar still covers content once the panel fits it")
        } else {
            XCTAssertTrue(frosts(bottomBar(), in: host), "the bottom bar doesn't frost over content once the panel fits it")
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

    /// Whether the content shows anywhere down the middle of `bar`: black, unless `matching` says otherwise.
    private func showsContent(
        in bar: NSRect,
        of host: NSView,
        matching: (NSColor) -> Bool = { $0.brightnessComponent < 0.5 }
    ) throws -> Bool {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        return stride(from: bar.minY, to: bar.maxY, by: 1).contains { y in
            let row = host.isFlipped ? y : host.bounds.maxY - y - 1
            let color = rep.colorAt(x: Int(bar.midX * scale), y: Int(row * scale))!.usingColorSpace(.deviceRGB)!
            return matching(color)
        }
    }

    private func visualEffectViews(in view: NSView) -> [NSVisualEffectView] {
        [view as? NSVisualEffectView].compactMap { $0 } + view.subviews.flatMap(visualEffectViews)
    }

    private static var content: some View {
        Color.black.frame(height: 1_000)
    }
}

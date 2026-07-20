import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class UsageTrendPopoverTests: XCTestCase {
    func testReducedMotionPopoverDisablesPresentationAnimation() {
        var isPresented = false
        let controller = ReducedMotionPopoverController(isPresented: Binding(
            get: { isPresented },
            set: { isPresented = $0 }
        ))

        XCTAssertFalse(controller.popover.animates)
        XCTAssertEqual(controller.popover.behavior, .transient)
    }

    func testClosedPopoverSkipsHiddenContentSizing() {
        var isPresented = false
        let controller = ReducedMotionPopoverController(isPresented: Binding(
            get: { isPresented },
            set: { isPresented = $0 }
        ))
        let originalSize = NSSize(width: 17, height: 19)
        controller.popover.contentSize = originalSize

        controller.update(
            content: AnyView(Color.clear.frame(width: 300, height: 200)),
            reduceAnimations: true,
            anchor: NSView()
        )

        XCTAssertEqual(controller.popover.contentSize, originalSize)
    }

    func testDismissAllClosesPresentedPopoverImmediately() {
        var isPresented = true
        let controller = ReducedMotionPopoverController(isPresented: Binding(
            get: { isPresented },
            set: { isPresented = $0 }
        ))
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 20))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 20),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = anchor
        window.orderFront(nil)
        defer { window.close() }

        controller.update(
            content: AnyView(Text("Detail").frame(width: 100, height: 50)),
            reduceAnimations: true,
            anchor: anchor
        )
        XCTAssertTrue(controller.popover.isShown)

        isPresented = false
        ReducedMotionPopoverController.dismissAll()

        XCTAssertFalse(controller.popover.isShown)
    }
}

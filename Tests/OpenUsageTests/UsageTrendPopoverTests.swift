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
}

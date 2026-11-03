import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class ScreenTransitionTests: XCTestCase {
    func testReducedMotionDisablesTheAnimationAndThePager() {
        var transaction = Transaction(animation: .linear(duration: 1))
        Motion.applyReduction(to: &transaction, enabled: true)
        XCTAssertNil(transaction.animation)
        XCTAssertTrue(transaction.disablesAnimations)
        XCTAssertFalse(DashboardView.screenTransitionIsActive(reduceAnimations: true, screenSlideID: 2, settledSlideID: 1))
    }

    func testSettingsSlidesWithItsChromeThenParksOffscreen() {
        let sliding: [PopoverScreen] = [.dashboard, .settings]
        XCTAssertTrue(DashboardView.settingsChromeIsVisible(pages: sliding))
        XCTAssertEqual(DashboardView.settingsOverlayOffset(pages: sliding, slideOffset: -100, pageWidth: 320), 220)

        let settled: [PopoverScreen] = [.dashboard]
        XCTAssertFalse(DashboardView.settingsChromeIsVisible(pages: settled))
        XCTAssertGreaterThanOrEqual(DashboardView.settingsOverlayOffset(pages: settled, slideOffset: 0, pageWidth: 320), 320)
    }
}

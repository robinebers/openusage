import XCTest
import SwiftUI
@testable import OpenUsage

@MainActor
final class ScreenTransitionTests: XCTestCase {
    func testRootTransactionOnlyDisablesAnimationsWhenReduced() {
        for reduced in [false, true] {
            var transaction = Transaction(animation: .linear(duration: 1))
            Motion.applyReduction(to: &transaction, enabled: reduced)

            XCTAssertEqual(transaction.animation == nil, reduced)
            XCTAssertEqual(transaction.disablesAnimations, reduced)
        }
    }

    func testReducedAnimationsNeverMountsScreenTransitionPager() {
        XCTAssertFalse(DashboardView.screenTransitionIsActive(reduceAnimations: true, screenSlideID: 2, settledSlideID: 1))
    }

    func testSettingsOverlayFollowsItsPagerSlotOrParksOffscreen() {
        let cases: [(pages: [PopoverScreen], offset: CGFloat, expected: CGFloat)] = [
            ([.dashboard, .settings], 0, 320),
            ([.dashboard, .settings], -320, 0),
            ([.settings], 0, 0),
            ([.dashboard], 0, 640),
            ([.dashboard, .accounts], -160, 640)
        ]

        for item in cases {
            XCTAssertEqual(
                DashboardView.settingsOverlayOffset(pages: item.pages, slideOffset: item.offset, pageWidth: 320),
                item.expected
            )
        }
    }

    func testSettingsChromeOnlyMountsWhileItsPageIsVisibleOrSliding() {
        XCTAssertTrue(DashboardView.settingsChromeIsVisible(pages: [.settings]))
        XCTAssertTrue(DashboardView.settingsChromeIsVisible(pages: [.dashboard, .settings]))
        XCTAssertTrue(DashboardView.settingsChromeIsVisible(pages: [.accounts, .settings]))
        XCTAssertFalse(DashboardView.settingsChromeIsVisible(pages: [.dashboard]))
        XCTAssertFalse(DashboardView.settingsChromeIsVisible(pages: [.accounts]))
        XCTAssertFalse(DashboardView.settingsChromeIsVisible(pages: [.dashboard, .accounts]))
    }

    func testNormalMotionKeepsScreenTransitionPagerUntilTheSlideSettles() {
        XCTAssertFalse(DashboardView.screenTransitionIsActive(reduceAnimations: false, screenSlideID: 0, settledSlideID: 0))
        XCTAssertTrue(DashboardView.screenTransitionIsActive(reduceAnimations: false, screenSlideID: 2, settledSlideID: 1))
        XCTAssertFalse(DashboardView.screenTransitionIsActive(reduceAnimations: false, screenSlideID: 2, settledSlideID: 2))
    }
}

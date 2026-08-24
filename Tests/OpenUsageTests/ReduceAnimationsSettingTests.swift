import XCTest
import SwiftUI
@testable import OpenUsage

@MainActor
final class ReduceAnimationsSettingTests: XCTestCase {
    func testEitherPreferenceReducesAnimations() {
        for (app, system, expected) in [(false, false, false), (true, false, true), (false, true, true)] {
            XCTAssertEqual(ReduceAnimationsSetting.resolve(appPreference: app, systemReduceMotion: system), expected)
        }
    }

    func testPersistenceKeyAndFallbackStayStable() {
        XCTAssertEqual(ReduceAnimationsSetting.key, "reduceAnimations")
        XCTAssertFalse(ReduceAnimationsSetting.fallback)
    }

    func testRootTransactionOnlyDisablesAnimationsWhenReduced() {
        for reduced in [false, true] {
            var transaction = Transaction(animation: .linear(duration: 1))
            Motion.applyReduction(to: &transaction, enabled: reduced)

            XCTAssertEqual(transaction.animation == nil, reduced)
            XCTAssertEqual(transaction.disablesAnimations, reduced)
        }
    }

    func testReducedAnimationsNeverMountsScreenTransitionPager() {
        XCTAssertFalse(DashboardView.screenTransitionIsActive(
            reduceAnimations: true,
            screenSlideID: 2,
            animatedSlideID: 1,
            slideProgress: 0
        ))
    }

    func testSettingsOverlayFollowsItsPagerSlotOrParksOffscreen() {
        let cases: [(pages: [PopoverScreen], offset: CGFloat, expected: CGFloat)] = [
            ([.dashboard, .settings], 0, 320),
            ([.dashboard, .settings], -320, 0),
            ([.settings], 0, 0),
            ([.dashboard], 0, 640),
            ([.dashboard, .customize], -160, 640)
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
        XCTAssertTrue(DashboardView.settingsChromeIsVisible(pages: [.customize, .settings]))
        XCTAssertFalse(DashboardView.settingsChromeIsVisible(pages: [.dashboard]))
        XCTAssertFalse(DashboardView.settingsChromeIsVisible(pages: [.customize]))
        XCTAssertFalse(DashboardView.settingsChromeIsVisible(pages: [.dashboard, .customize]))
    }

    func testNormalMotionKeepsScreenTransitionPagerUntilCompletion() {
        XCTAssertTrue(DashboardView.screenTransitionIsActive(
            reduceAnimations: false,
            screenSlideID: 2,
            animatedSlideID: 1,
            slideProgress: 0
        ))
        XCTAssertFalse(DashboardView.screenTransitionIsActive(
            reduceAnimations: false,
            screenSlideID: 2,
            animatedSlideID: 2,
            slideProgress: 1
        ))
    }

    func testContinuousMotionUsesBaselineWhenAnimationsAreReduced() {
        XCTAssertEqual(
            MotionTimelineMode.resolve(popoverShown: true, reduceAnimations: true),
            .baselineStatic
        )
        XCTAssertEqual(
            MotionTimelineMode.resolve(popoverShown: false, reduceAnimations: true),
            .baselineStatic
        )
    }

    func testContinuousMotionOnlyRunsWhileVisibleWithoutReduction() {
        XCTAssertEqual(
            MotionTimelineMode.resolve(popoverShown: true, reduceAnimations: false),
            .live
        )
        XCTAssertEqual(
            MotionTimelineMode.resolve(popoverShown: false, reduceAnimations: false),
            .currentStatic
        )
    }
}

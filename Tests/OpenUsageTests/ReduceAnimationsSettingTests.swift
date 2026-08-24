import XCTest
import SwiftUI
@testable import OpenUsage

@MainActor
final class ReduceAnimationsSettingTests: XCTestCase {
    func testMotionStaysEnabledWithoutEitherPreference() {
        XCTAssertFalse(ReduceAnimationsSetting.resolve(appPreference: false, systemReduceMotion: false))
    }

    func testAppPreferenceReducesAnimations() {
        XCTAssertTrue(ReduceAnimationsSetting.resolve(appPreference: true, systemReduceMotion: false))
    }

    func testSystemPreferenceReducesAnimations() {
        XCTAssertTrue(ReduceAnimationsSetting.resolve(appPreference: false, systemReduceMotion: true))
    }

    func testPersistenceKeyAndFallbackStayStable() {
        XCTAssertEqual(ReduceAnimationsSetting.key, "reduceAnimations")
        XCTAssertFalse(ReduceAnimationsSetting.fallback)
    }

    func testReducedAnimationsClearsAndLocksTheRootTransaction() {
        var transaction = Transaction(animation: .linear(duration: 1))

        Motion.applyReduction(to: &transaction, enabled: true)

        XCTAssertNil(transaction.animation)
        XCTAssertTrue(transaction.disablesAnimations)
    }

    func testNormalMotionLeavesTheRootTransactionUntouched() {
        var transaction = Transaction(animation: .linear(duration: 1))

        Motion.applyReduction(to: &transaction, enabled: false)

        XCTAssertNotNil(transaction.animation)
        XCTAssertFalse(transaction.disablesAnimations)
    }

    func testReducedAnimationsNeverMountsScreenTransitionPager() {
        XCTAssertFalse(DashboardView.screenTransitionIsActive(
            reduceAnimations: true,
            screenSlideID: 2,
            animatedSlideID: 1,
            slideProgress: 0
        ))
    }

    func testSettingsOverlayFollowsItsPagerSlotDuringASlide() {
        XCTAssertEqual(
            DashboardView.settingsOverlayOffset(
                pages: [.dashboard, .settings],
                slideOffset: 0,
                pageWidth: 320
            ),
            320
        )
        XCTAssertEqual(
            DashboardView.settingsOverlayOffset(
                pages: [.dashboard, .settings],
                slideOffset: -320,
                pageWidth: 320
            ),
            0
        )
        XCTAssertEqual(
            DashboardView.settingsOverlayOffset(
                pages: [.settings],
                slideOffset: 0,
                pageWidth: 320
            ),
            0
        )
    }

    func testSettingsOverlayParksOffscreenWhenNotInThePager() {
        XCTAssertEqual(
            DashboardView.settingsOverlayOffset(
                pages: [.dashboard],
                slideOffset: 0,
                pageWidth: 320
            ),
            640
        )
        XCTAssertEqual(
            DashboardView.settingsOverlayOffset(
                pages: [.dashboard, .customize],
                slideOffset: -160,
                pageWidth: 320
            ),
            640
        )
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

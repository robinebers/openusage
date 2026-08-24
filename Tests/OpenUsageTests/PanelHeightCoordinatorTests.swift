import Observation
import os
import XCTest
@testable import OpenUsage

/// The popover auto-fit height computation, now unit-testable after being split out of DashboardView:
/// each screen's ideal = (top bar unless dashboard) + footer + scroll content, and `target` clamps it.
@MainActor
final class PanelHeightCoordinatorTests: XCTestCase {
    private let topBar: CGFloat = 44

    func testDashboardIdealOmitsTopBar() {
        let c = PanelHeightCoordinator(topBarHeight: topBar)
        c.setScrollContent(300, for: .dashboard)
        c.setFooter(40, for: .dashboard)
        // Dashboard has no top bar: ideal = content + footer.
        XCTAssertEqual(c.measuredIdeal[.dashboard], 340)
    }

    func testOtherScreensIncludeTopBar() {
        let c = PanelHeightCoordinator(topBarHeight: topBar)
        c.setScrollContent(300, for: .customize)
        c.setFooter(40, for: .customize)
        // Customize/Settings pin the fixed top bar: ideal = topBar + footer + content.
        XCTAssertEqual(c.measuredIdeal[.customize], 44 + 40 + 300)
    }

    func testFooterDefaultsToZeroUntilMeasured() {
        let c = PanelHeightCoordinator(topBarHeight: topBar)
        c.setScrollContent(300, for: .settings)
        XCTAssertEqual(c.measuredIdeal[.settings], 44 + 300)
    }

    func testIdealUnsetUntilScrollContentMeasured() {
        let c = PanelHeightCoordinator(topBarHeight: topBar)
        // A footer measurement alone (no scroll content yet) leaves the ideal unset — the view keeps the
        // controller's opening size until real content lands.
        c.setFooter(40, for: .dashboard)
        XCTAssertNil(c.measuredIdeal[.dashboard])
        // A zero-height content measurement is also ignored.
        c.setScrollContent(0, for: .dashboard)
        XCTAssertNil(c.measuredIdeal[.dashboard])
    }

    func testTargetIsNilUntilMeasuredThenClamps() {
        // The clamp hook is a process global (see PanelHeightBridgeTests for the same reset pattern):
        // pin it explicitly on both branches so this test can't depend on suite order.
        let previousClamp = MenuBarPopover.clampHeight
        defer { MenuBarPopover.clampHeight = previousClamp }

        let c = PanelHeightCoordinator(topBarHeight: topBar)
        XCTAssertNil(c.target(for: .dashboard))

        MenuBarPopover.clampHeight = nil
        c.setScrollContent(300, for: .dashboard)
        // No clamp hook installed → target is the raw ideal.
        XCTAssertEqual(c.target(for: .dashboard), 300)

        // With the panel's hook installed, the target is floored and capped at both edges.
        MenuBarPopover.clampHeight = { min(max($0, 400), 600) }
        XCTAssertEqual(c.target(for: .dashboard), 400)  // 300 floored to the panel minimum
        c.setScrollContent(900, for: .dashboard)
        XCTAssertEqual(c.target(for: .dashboard), 600)  // 900 capped at the screen max
        c.setScrollContent(500, for: .dashboard)
        XCTAssertEqual(c.target(for: .dashboard), 500)  // in-range ideals pass through
    }

    func testLaterMeasurementRecomposesIdeal() {
        let c = PanelHeightCoordinator(topBarHeight: topBar)
        c.setScrollContent(300, for: .dashboard)
        XCTAssertEqual(c.measuredIdeal[.dashboard], 300)
        c.setScrollContent(500, for: .dashboard)   // content grew (rows loaded)
        XCTAssertEqual(c.measuredIdeal[.dashboard], 500)
    }

    func testRepeatedMeasurementsDoNotInvalidateHeightObservers() {
        let coordinator = PanelHeightCoordinator(topBarHeight: topBar)
        coordinator.setScrollContent(300, for: .dashboard)
        coordinator.setFooter(40, for: .dashboard)

        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = coordinator.measuredIdeal
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        coordinator.setScrollContent(300, for: .dashboard)
        coordinator.setFooter(40, for: .dashboard)

        XCTAssertFalse(invalidated.withLock { $0 })
        XCTAssertEqual(coordinator.measuredIdeal[.dashboard], 340)
    }

    func testChangedMeasurementStillInvalidatesHeightObservers() {
        let coordinator = PanelHeightCoordinator(topBarHeight: topBar)
        coordinator.setScrollContent(300, for: .dashboard)

        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = coordinator.measuredIdeal
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        coordinator.setScrollContent(420, for: .dashboard)

        XCTAssertTrue(invalidated.withLock { $0 })
        XCTAssertEqual(coordinator.measuredIdeal[.dashboard], 420)
    }
}

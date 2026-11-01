import XCTest
@testable import OpenUsage

final class MeasuredPanelHeightsTests: XCTestCase {
    func testEachDashboardTabKeepsItsOwnHeight() {
        var heights = MeasuredPanelHeights()
        heights[.dashboard, .allUsage] = 700

        XCTAssertNil(heights[.dashboard, .priority], "Priority would open at All Usage's height")

        heights[.dashboard, .priority] = 400
        XCTAssertEqual(heights[.dashboard, .allUsage], 700)
        XCTAssertEqual(heights[.dashboard, .priority], 400)
    }

    func testOtherScreensIgnoreTheTab() {
        var heights = MeasuredPanelHeights()
        heights[.settings, .priority] = 500

        XCTAssertEqual(heights[.settings, .allUsage], 500)
    }
}

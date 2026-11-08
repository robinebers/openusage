import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DashboardLabelFitTests: XCTestCase {
    func testBoundedAmountsAndMetricNamesFitTheirColumns() {
        func width(_ text: Text) -> CGFloat { NSHostingView(rootView: text.fixedSize()).fittingSize.width }
        let amount = Text("$999.99").font(DashboardMetricRow.font).monospacedDigit()
        XCTAssertLessThanOrEqual(width(amount), DashboardGrid.valueWidth)

        XCTAssertLessThanOrEqual(width(Text("Free Requests").font(DashboardMetricRow.font)), DashboardGrid.labelWidth)
    }

    func testEveryClockResetFitsItsColumn() {
        let evening = Calendar.current.date(bySettingHour: 22, minute: 58, second: 0, of: Date())!
        for day in 0..<7 {
            let date = evening.addingTimeInterval(TimeInterval(day) * 86_400)
            for label in [TimeFormatSetting.twelveHour.weekdayTime(date), TimeFormatSetting.twentyFourHour.weekdayTime(date)] {
                let text = Text(label).font(DashboardMetricRow.resetFont).monospacedDigit().fixedSize()
                XCTAssertLessThanOrEqual(NSHostingView(rootView: text).fittingSize.width, DashboardGrid.clockResetWidth, label)
            }
        }
    }

    func testLongAccountNameLeavesThePlanReadable() throws {
        let width = PanelMetrics.width - 2 * PanelMetrics.margin - 2 * DashboardGrid.cardPadding
        let plan = "SuperGrok Heavy"
        let planTextWidth = NSHostingView(rootView: Text(plan).font(DashboardGrid.planFont).fixedSize()).fittingSize.width
        func planInk(beside label: String) throws -> Int {
            let provider = Provider(id: "grok", kind: .grok, accountLabel: label)
            let caption = DashboardAccountCaption(account: DashboardAccount(provider: provider, lines: []), plan: plan)
                .environment(AccountRenameStore?.none)
                .padding(.leading, 8) // Keep InkMap's reference column outside the text.
            let map = try InkMap(rendering: caption, width: width + 8, scale: 2)
            let right = width + 8 - DashboardGrid.planPadding
            return map.count(x: (right - ceil(planTextWidth))..<right, y: 0..<CGFloat(map.height) / map.scale)
        }

        let fullPlan = try planInk(beside: "Work")
        XCTAssertGreaterThan(fullPlan, 0)
        XCTAssertEqual(try planInk(beside: "a-very-long-account-name-that-cannot-fit@example.com"), fullPlan)
    }
}

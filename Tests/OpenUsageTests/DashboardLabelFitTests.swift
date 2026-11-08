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

    func testEveryEnglishClockResetFitsItsColumn() {
        let english = Locale(identifier: "en_US")
        let mornings: [Date] = (0..<7).map { Date(timeIntervalSince1970: 1_794_394_680 + Double($0) * 86_400) } // Wed 2026-11-11 10:58 UTC
        for date in mornings + mornings.map({ $0.addingTimeInterval(12 * 3600) }) {
            for label in [TimeFormatSetting.twelveHour.weekdayTime(date, base: english, timeZone: .gmt), TimeFormatSetting.twentyFourHour.weekdayTime(date, base: english, timeZone: .gmt)] {
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

import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class ProviderHeaderLayoutTests: XCTestCase {
    private let boxWidth = PanelMetrics.width - 2 * PanelMetrics.margin
    private let inset = DashboardGrid.cardPadding + DashboardGrid.inset

    private func claude(_ label: String?, _ id: String = "claude@1") -> Provider {
        Provider(id: id, kind: .claude, accountLabel: label)
    }

    private func family(_ accounts: [Provider], lines: [DashboardLine] = []) -> DashboardFamily {
        DashboardFamily(id: "claude", provider: accounts[0], accounts: accounts.map { DashboardAccount(provider: $0, lines: lines) })
    }

    private func section(_ family: DashboardFamily, plans: [String: String] = [:], isCaptioned: Bool = true) -> DashboardProviderSection<DashboardProviderHeader, DashboardAccountRows> {
        DashboardProviderSection(family: family, plans: plans) { account in
            DashboardAccountRows(account: account, plan: plans[account.id], isCaptioned: isCaptioned)
        }
    }

    private func line(_ data: WidgetData) -> DashboardLine {
        DashboardLine(descriptor: WidgetDescriptor(provider: Provider(id: "p", kind: .claude), key: data.title, metricLabel: data.title, sample: data), data: data)
    }

    private func percent(_ title: String, used: Double, resetsIn: TimeInterval? = nil) -> WidgetData {
        var data = WidgetData(title: title, kind: .percent, used: used, limit: 100)
        data.displayMode = .remaining
        data.resetsAt = resetsIn.map { Date().addingTimeInterval($0) }
        return data
    }

    private var logoStart: CGFloat { boxWidth - inset - DashboardGrid.iconSize }

    private func text(_ string: String, _ font: Font) throws -> CGFloat {
        try XCTUnwrap(InkMap(rendering: Text(string).font(font).fixedSize().padding(20), width: 400, scale: 2).span()).width
    }

    func testASoleAccountsHeaderNamesTheProviderAccountAndPlanWithTheLogoTrailing() throws {
        let bitmap = try InkMap(rendering: section(family([claude("Sunstory")]), plans: ["claude@1": "Max 20x"]).header, width: boxWidth, scale: 2)
        XCTAssertEqual(CGFloat(bitmap.height) / bitmap.scale, DashboardGrid.headerHeight)

        let logo = try XCTUnwrap(bitmap.span(from: logoStart - 1, to: boxWidth), "no logo at the trailing end")
        XCTAssertEqual(logo.last, boxWidth - inset, accuracy: 1.5, "the logo doesn't end at the card's inset")

        let title = try XCTUnwrap(bitmap.span(from: 0, to: logoStart - 2), "no title")
        XCTAssertEqual(title.first, inset, accuracy: 1.5, "the title doesn't start at the card's inset")
        let name = try text("Claude — Sunstory", DashboardGrid.headerFont)
        let plan = try text("Max 20x", DashboardGrid.planFont)
        XCTAssertEqual(title.width, name + DashboardGrid.amountGap + plan, accuracy: 3, "the title isn't the provider, the account and the plan")
    }

    func testAHeaderOverSeveralAccountsNamesOnlyTheProvider() throws {
        let several = section(family([claude("Personal"), claude("Work", "claude@2")]), plans: ["claude@1": "Max 20x", "claude@2": "Max 5x"])
        let bitmap = try InkMap(rendering: several.header, width: boxWidth, scale: 2)
        let title = try XCTUnwrap(bitmap.span(from: 0, to: logoStart - 2))
        XCTAssertEqual(title.width, try text("Claude", DashboardGrid.headerFont), accuracy: 1.5, "the header draws more than the provider's name")
    }

    func testAnAccountNamedLikeItsProviderReadsOnce() throws {
        for name in ["Claude", nil] {
            let bitmap = try InkMap(rendering: section(family([claude(name)])).header, width: boxWidth, scale: 2)
            let title = try XCTUnwrap(bitmap.span(from: 0, to: logoStart - 2))
            XCTAssertEqual(title.width, try text("Claude", DashboardGrid.headerFont), accuracy: 1.5, name ?? "unnamed")
        }
    }

    func testALongAccountNameTruncatesBeforeThePlanDoes() throws {
        let long = family([claude("An Account Name Far Too Long For This Header To Hold")])
        let bitmap = try InkMap(rendering: section(long, plans: ["claude@1": "Max 20x"]).header, width: boxWidth, scale: 2)
        let plan = try text("Max 20x", DashboardGrid.planFont)
        let planEnd = logoStart - DashboardGrid.columnGap
        let drawn = try XCTUnwrap(bitmap.span(from: planEnd - plan - 2, to: logoStart - 2), "no plan")
        XCTAssertGreaterThan(drawn.last, planEnd - 8, "the plan doesn't sit by the logo")
        XCTAssertLessThanOrEqual(drawn.last, planEnd + 1, "the plan runs into the logo")
        XCTAssertEqual(drawn.width, plan, accuracy: 3, "the plan was cut")
    }

    func testOnlySeveralAccountsAreCaptioned() throws {
        let rows = [line(percent("Session", used: 8)), line(percent("Weekly", used: 81))]
        let sole = section(family([claude("Personal")], lines: rows), plans: ["claude@1": "Max 20x"], isCaptioned: false)
        XCTAssertEqual(try InkMap(rendering: sole, width: boxWidth).bands().count, 5, "a header, then two limits of text over a bar")

        let several = section(family([claude("Personal"), claude("Work", "claude@2")], lines: rows), plans: ["claude@1": "Max 20x", "claude@2": "Max 5x"])
        XCTAssertEqual(try InkMap(rendering: several, width: boxWidth).bands().count, 11, "a header, then a caption and two limits per account")
    }

    func testCaptionsHeadersAndRowsShareTheirEdges() throws {
        let rows = [line(percent("Session", used: 0, resetsIn: 3 * 3600)), line(percent("Weekly", used: 24, resetsIn: 86_400))]
        let two = family([claude("Personal"), claude("Work", "claude@2")], lines: rows)
        let bands = try InkMap(rendering: section(two, plans: ["claude@1": "Max 5x", "claude@2": "Max 5x"]), width: boxWidth, scale: 2).bands()
        XCTAssertEqual(bands.count, 11)
        let edges = bands.map(\.first)
        XCTAssertLessThanOrEqual((edges.max() ?? 0) - (edges.min() ?? 0), 1.5, "leading edges \(edges)")
        XCTAssertEqual(edges.min() ?? 0, inset, accuracy: 1.5)
        for band in bands[1...] {
            XCTAssertEqual(band.last, boxWidth - inset, accuracy: 1.5, "every caption, reset and bar ends at the card's inset")
        }
    }

    func testALimitIsItsLabelAmountAndResetOverAFullWidthBar() throws {
        let row = DashboardMetricRow(model: percent("Weekly", used: 0, resetsIn: 5 * 3600).dashboardRow())
            .padding(.horizontal, DashboardGrid.cardPadding)
        let bands = try InkMap(rendering: row, width: boxWidth, scale: 2).bands()
        XCTAssertEqual(bands.count, 2, "a limit is two lines")
        XCTAssertEqual(bands[0].first, inset, accuracy: 1.5)
        XCTAssertEqual(bands[0].last, boxWidth - inset, accuracy: 1.5, "the reset isn't right-aligned")
        XCTAssertEqual(bands[1].first, inset, accuracy: 1.5, "the bar doesn't start at the label")
        XCTAssertEqual(bands[1].last, boxWidth - inset, accuracy: 1.5, "the bar doesn't fill the row")
    }

    func testAValueRowPutsItsLabelLeftAndItsValueRightWithNoBar() throws {
        var today = WidgetData(title: "Today", kind: .dollars, used: 0, limit: nil)
        today.values = [MetricValue(number: 12.5, kind: .dollars), MetricValue(number: 3_000, kind: .count, label: "tokens")]
        let row = DashboardMetricRow(model: today.dashboardRow()).padding(.horizontal, DashboardGrid.cardPadding)
        let bands = try InkMap(rendering: row, width: boxWidth, scale: 2).bands()

        XCTAssertEqual(bands.count, 1, "a value row has no bar")
        XCTAssertEqual(bands[0].first, inset, accuracy: 1.5)
        XCTAssertEqual(bands[0].last, boxWidth - inset, accuracy: 1.5, "the value isn't right-aligned")
    }

    func testTheGapsBetweenRowsSayWhatTheyAre() {
        func dashboardLine(bounded: Bool) -> DashboardLine {
            line(WidgetData(title: "Row", kind: .dollars, used: 1, limit: bounded ? 100 : nil))
        }
        let bar = dashboardLine(bounded: true), value = dashboardLine(bounded: false)
        XCTAssertEqual(DashboardGrid.gap(above: bar, after: nil), 0)
        XCTAssertEqual(DashboardGrid.gap(above: bar, after: bar), 9)
        XCTAssertEqual(DashboardGrid.gap(above: value, after: value), 6)
        XCTAssertEqual(DashboardGrid.gap(above: value, after: bar), 14, "6 pt plus 8 extra after the bars")
        XCTAssertEqual(DashboardGrid.gap(above: bar, after: value), 14)
    }

    func testTheHeaderAndCaptionUseTheirFonts() {
        XCTAssertEqual(DashboardGrid.headerHeight, DashboardGrid.lineHeight(.systemFont(ofSize: 15, weight: .semibold)))
        XCTAssertEqual(DashboardGrid.captionHeight, DashboardGrid.lineHeight(.systemFont(ofSize: 11)))
        XCTAssertEqual(DashboardGrid.iconSize, DashboardGrid.headerHeight, "the logo isn't as tall as the header's line")
        XCTAssertEqual(DashboardGrid.sectionSpacing, 16)
    }
}

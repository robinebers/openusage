import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DashboardSectionTests: QuietWindowTestCase {
    private final class Log {
        var accountDrags = 0
        var metricDrags = 0
        var headerDrags = 0
        var styleFlips = 0
        var resetFlips = 0
    }

    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let renaming: AccountRenameStore
        let accountID: String
    }

    private static let captionY = DashboardGrid.headerHeight + DashboardGrid.headerGap + DashboardGrid.cardPadding + DashboardGrid.captionHeight / 2
    private static let firstRowY = DashboardGrid.headerHeight + DashboardGrid.headerGap + DashboardGrid.cardPadding
        + DashboardGrid.captionHeight + DashboardGrid.rowHeight / 2
    private static let nameX = DashboardGrid.cardPadding + DashboardGrid.inset + 10
    private static let headerNameX = DashboardGrid.cardPadding + DashboardGrid.inset + DashboardGrid.iconSize + DashboardGrid.columnGap + 10

    private let lines: [DashboardLine] = ["Session", "Weekly", "Fable"].map { title in
        var data = WidgetData(title: title, kind: .percent, used: 30, limit: 100)
        data.resetsAt = Date().addingTimeInterval(86_400)
        data.periodDurationMs = 7 * 86_400 * 1000
        return DashboardLine(descriptor: WidgetDescriptor(provider: Provider(id: "claude", kind: .claude), key: title, metricLabel: title, sample: data), data: data)
    }

    private let resets: DashboardLine = {
        var data = WidgetData(title: "Limit Resets", kind: .count, used: 2, limit: nil)
        data.values = [MetricValue(number: 2, kind: .count, label: "available")]
        data.showsResetExpiries = true
        data.expiriesAt = [Date().addingTimeInterval(3 * 86_400), Date().addingTimeInterval(20 * 86_400)]
        return DashboardLine(descriptor: WidgetDescriptor(provider: Provider(id: "claude", kind: .claude), key: "resets", metricLabel: "Limit Resets", sample: data), data: data)
    }()

    private let work = Provider(id: "claude@2", kind: .claude, accountLabel: "Work")

    private func account(_ provider: Provider, lines: [DashboardLine]? = nil) -> DashboardAccount {
        DashboardAccount(provider: provider, lines: lines ?? self.lines)
    }

    func testOnlyTheResetsCountOpensAPopoverAndEveryOtherRowDrawsAsAtRest() throws {
        let log = Log()
        let hosted = hostWithRenaming(log: log, lines: lines + [resets])
        let shown = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        func opened() -> [NSWindow] { NSApp.windows.filter { $0.isVisible && !shown.contains(ObjectIdentifier($0)) } }
        let height = hosted.host.fittingSize.height
        let atRest = try pixels(of: hosted.host)
        let resetsRowY = Self.firstRowY + 3 * DashboardGrid.rowHeight
        let figureX = DashboardGrid.cardPadding + DashboardGrid.inset + DashboardGrid.labelWidth + DashboardGrid.columnGap + 12
        let trailing = hosted.host.bounds.width - DashboardGrid.cardPadding - DashboardGrid.inset

        for (name, point) in [("the name", CGPoint(x: Self.nameX, y: Self.captionY)),
                              ("a row's label", CGPoint(x: Self.nameX, y: Self.firstRowY)),
                              ("the resets row's label", CGPoint(x: Self.nameX, y: resetsRowY))] {
            try hover(point, hosted.window, hosted.host)
            XCTAssertTrue(opened().isEmpty, "hovering \(name) opens something")
            XCTAssertNil(HoverTooltips.visibleText, "hovering \(name) shows a tooltip")
            XCTAssertEqual(try pixels(of: hosted.host), atRest, "\(name) under the pointer draws differently from at rest")
            try leave(hosted.window, hosted.host)
        }

        let session = lines[0].data
        for (name, point, text) in [("the bar", CGPoint(x: hosted.host.bounds.width / 2, y: Self.firstRowY), session.paceTooltip()),
                                    ("the value", CGPoint(x: trailing - DashboardGrid.resetWidth - DashboardGrid.columnGap - 10, y: Self.firstRowY), session.meterStyleTooltip),
                                    ("the reset", CGPoint(x: trailing - 10, y: Self.firstRowY), session.resetTooltip())] {
            try hover(point, hosted.window, hosted.host)
            XCTAssertEqual(opened().count, 1, "hovering \(name) opens no tooltip")
            XCTAssertEqual(HoverTooltips.visibleText, try XCTUnwrap(text), "the tooltip on \(name) reads something else")
            XCTAssertEqual(try pixels(of: hosted.host), atRest, "\(name) under the pointer draws differently from at rest")
            try leave(hosted.window, hosted.host)
            XCTAssertTrue(opened().isEmpty, "the tooltip on \(name) stayed after the pointer left")
        }

        try hover(CGPoint(x: figureX, y: resetsRowY), hosted.window, hosted.host)
        XCTAssertFalse(opened().isEmpty, "hovering the resets count opens no popover")
        XCTAssertEqual(hosted.host.fittingSize.height, height, "the hover changed the height")
        XCTAssertEqual(log.accountDrags + log.metricDrags, 0)
        HoverPopoverState.dismissAll()
    }

    func testHoveringTheWarningShowsTheNoticeAndHoveringTheNameShowsNothing() throws {
        let notice = "Refresh failed: the token has expired."
        let (renaming, provider) = storedAccount(label: "Work")
        let family = DashboardFamily(id: "claude", provider: provider, accounts: [account(provider)])
        let section = DashboardProviderSection(family: family) { account in
            VStack(alignment: .leading, spacing: 0) {
                DashboardAccountCaption(account: account, plan: "Max 5x", status: AccountStatus(notice: notice))
                ForEach(account.lines) { DashboardMetricRow(model: $0.data.dashboardRow()) }
            }
        }
        let (window, host) = hostView(section, renaming: renaming)
        let shown = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        func opened() -> [NSWindow] { NSApp.windows.filter { $0.isVisible && !shown.contains(ObjectIdentifier($0)) } }
        let headerMid = DashboardGrid.headerHeight / 2
        let captionFont = NSFont.systemFont(ofSize: DashboardGrid.planNSFont.pointSize, weight: .semibold)
        let nameEnd = Self.nameX - 10 + ("Work" as NSString).size(withAttributes: [.font: captionFont]).width

        try hover(CGPoint(x: DashboardGrid.cardPadding + DashboardGrid.inset + DashboardGrid.iconSize / 2, y: headerMid), window, host)
        XCTAssertTrue(opened().isEmpty, "hovering the logo opens something")
        XCTAssertNil(HoverTooltips.visibleText)

        try hover(CGPoint(x: Self.headerNameX, y: headerMid), window, host)
        XCTAssertTrue(opened().isEmpty, "hovering the provider's name opens something")
        XCTAssertNil(HoverTooltips.visibleText)

        try hover(CGPoint(x: Self.nameX, y: Self.captionY), window, host)
        XCTAssertTrue(opened().isEmpty, "hovering the account's name opens something")
        XCTAssertNil(HoverTooltips.visibleText)

        try hover(CGPoint(x: nameEnd + Theme.Spacing.s + 5, y: Self.captionY), window, host)
        let tooltip = try XCTUnwrap(opened().first, "hovering the warning opens no tooltip")
        XCTAssertEqual(opened().count, 1)
        XCTAssertFalse(tooltip.isKeyWindow, "the tooltip took the keyboard")
        XCTAssertEqual(HoverTooltips.visibleText, notice, "the tooltip doesn't read the notice")

        try leave(window, host)
        XCTAssertTrue(opened().isEmpty, "the tooltip stayed after the pointer left")
        XCTAssertNil(HoverTooltips.visibleText)
    }

    func testClickingTheValueOrTheResetFlipsItsDisplayAndTheRestOfTheRowDoesNot() {
        let log = Log()
        let hosted = hostWithRenaming(log: log)
        let shown = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let resetX = hosted.host.bounds.width - DashboardGrid.cardPadding - DashboardGrid.inset - 6
        let valueX = resetX - DashboardGrid.resetWidth - DashboardGrid.columnGap

        click(CGPoint(x: Self.nameX, y: Self.firstRowY), hosted.window, hosted.host)
        click(CGPoint(x: hosted.host.bounds.width / 2, y: Self.firstRowY), hosted.window, hosted.host)
        XCTAssertEqual(log.styleFlips + log.resetFlips, 0, "a click on the label or the bar flipped a display")

        click(CGPoint(x: valueX, y: Self.firstRowY), hosted.window, hosted.host)
        XCTAssertEqual(log.styleFlips, 1, "a click on the value didn't flip the meter style")
        XCTAssertEqual(log.resetFlips, 0)

        click(CGPoint(x: resetX, y: Self.firstRowY), hosted.window, hosted.host)
        XCTAssertEqual(log.resetFlips, 1, "a click on the reset didn't flip the reset display")
        click(CGPoint(x: resetX, y: Self.firstRowY + DashboardGrid.rowHeight), hosted.window, hosted.host)
        XCTAssertEqual(log.resetFlips, 2, "a click on the second row's reset didn't flip the reset display")
        XCTAssertEqual(log.styleFlips, 1)

        XCTAssertFalse(NSApp.windows.contains { $0.isVisible && !shown.contains(ObjectIdentifier($0)) }, "a click opened a window")
        XCTAssertEqual(log.accountDrags + log.metricDrags, 0)
        XCTAssertNil(hosted.renaming.edit)
    }

    func testClicksChangeNothing() throws {
        let log = Log()
        let hosted = hostWithRenaming(log: log)
        let shown = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let points = [
            CGPoint(x: Self.nameX, y: Self.captionY),
            CGPoint(x: hosted.host.bounds.width - DashboardGrid.cardPadding - DashboardGrid.inset - 12, y: Self.captionY),
            CGPoint(x: hosted.host.bounds.width / 2, y: Self.firstRowY),
        ]
        for point in points {
            send(.mouseMoved, at: point, hosted.window, hosted.host)
            send(.leftMouseDown, at: point, hosted.window, hosted.host)
            send(.leftMouseUp, at: point, hosted.window, hosted.host)
            XCTAssertFalse(NSApp.windows.contains { $0.isVisible && !shown.contains(ObjectIdentifier($0)) }, "a click at \(point) opened a window")
            send(.mouseMoved, at: CGPoint(x: hosted.host.bounds.width / 2, y: DashboardGrid.headerHeight / 2), hosted.window, hosted.host)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertEqual(log.accountDrags + log.metricDrags, 0)
        XCTAssertNil(hosted.renaming.edit, "a click started a rename")
    }

    func testTheCaptionDragsTheAccountAndARowDragsItself() {
        let log = Log()
        let hosted = hostWithRenaming(log: log)
        drag(from: CGPoint(x: hosted.host.bounds.width / 2, y: Self.captionY), hosted.window, hosted.host)
        XCTAssertGreaterThan(log.accountDrags, 0)
        XCTAssertEqual(log.metricDrags, 0)

        log.accountDrags = 0
        drag(from: CGPoint(x: hosted.host.bounds.width / 2, y: Self.firstRowY), hosted.window, hosted.host)
        XCTAssertGreaterThan(log.metricDrags, 0)
        XCTAssertEqual(log.accountDrags, 0)
    }

    func testDoubleClickingTheNameRenamesTheAccountAndASingleClickDoesNot() throws {
        let log = Log()
        let hosted = hostWithRenaming(log: log)
        let name = CGPoint(x: Self.nameX, y: Self.captionY)

        click(name, hosted.window, hosted.host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(hosted.renaming.edit, "a single click on the name starts a rename")

        doubleClick(CGPoint(x: hosted.host.bounds.width / 2, y: name.y), hosted.window, hosted.host)
        XCTAssertNil(hosted.renaming.edit, "a double-click beside the name starts a rename")

        doubleClick(name, hosted.window, hosted.host)
        XCTAssertEqual(hosted.renaming.edit?.providerID, hosted.accountID, "a double-click on the name opens no rename")
        XCTAssertEqual(hosted.renaming.draft, "Personal")
        try assertWholeNameSelected("Personal", in: hosted.window)
        XCTAssertEqual(log.accountDrags + log.metricDrags, 0)
    }

    func testAOneAccountCardIsCaptionedLikeAnyOther() throws {
        let log = Log()
        let (renaming, provider) = storedAccount(label: "Work")
        let family = DashboardFamily(id: "claude", provider: provider, accounts: [account(provider)])
        let section = DashboardProviderSection(family: family) {
            DashboardProviderHeader(provider: provider)
                .highPriorityGesture(DragGesture(minimumDistance: 4).onChanged { _ in log.headerDrags += 1 })
        } account: { account in
            VStack(alignment: .leading, spacing: 0) {
                DashboardAccountCaption(account: account, plan: "Max 5x")
                    .highPriorityGesture(DragGesture(minimumDistance: 4).onChanged { _ in log.accountDrags += 1 })
                ForEach(account.lines) { DashboardMetricRow(model: $0.data.dashboardRow()) }
            }
        }
        let (window, host) = hostView(section, renaming: renaming)

        XCTAssertEqual(
            host.fittingSize.height,
            DashboardGrid.headerHeight + DashboardGrid.headerGap + 2 * DashboardGrid.cardPadding + DashboardGrid.captionHeight + 3 * DashboardGrid.rowHeight,
            accuracy: 1,
            "a header and a card of a caption over three rows"
        )

        let headerMid = DashboardGrid.headerHeight / 2
        doubleClick(CGPoint(x: Self.headerNameX, y: headerMid), window, host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(renaming.edit, "a double-click on the provider's name starts a rename")

        let name = CGPoint(x: Self.nameX, y: Self.captionY)
        click(name, window, host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(renaming.edit, "a single click on the caption's name starts a rename")

        doubleClick(name, window, host)
        XCTAssertEqual(renaming.edit?.providerID, provider.id, "a double-click on the caption's name opens no rename")
        XCTAssertEqual(renaming.draft, "Work")
        try assertWholeNameSelected("Work", in: window)
        renaming.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        drag(from: CGPoint(x: host.bounds.width / 2, y: headerMid), window, host)
        XCTAssertGreaterThan(log.headerDrags, 0, "the header doesn't drag the provider")
        drag(from: CGPoint(x: host.bounds.width / 2, y: Self.captionY), window, host)
        XCTAssertGreaterThan(log.accountDrags, 0, "the caption doesn't drag the account")
        XCTAssertNil(renaming.edit)
    }

    func testARenameFromTheMenuSelectsTheWholeName() throws {
        let hosted = hostWithRenaming(log: Log())
        hosted.renaming.begin(hosted.accountID)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try assertWholeNameSelected("Personal", in: hosted.window)
    }

    private func assertWholeNameSelected(_ name: String, in window: NSWindow, line: UInt = #line) throws {
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the rename field doesn't take focus", line: line)
        XCTAssertEqual(editor.string, name, line: line)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (name as NSString).length), "the whole name isn't selected", line: line)
    }

    func testDraggingTheNameDragsTheAccountAtOnce() {
        let log = Log()
        let hosted = hostWithRenaming(log: log)
        let name = CGPoint(x: Self.nameX, y: Self.captionY)

        send(.leftMouseDown, at: name, hosted.window, hosted.host)
        send(.leftMouseDragged, at: CGPoint(x: name.x, y: name.y + 12), hosted.window, hosted.host)
        XCTAssertGreaterThan(log.accountDrags, 0, "the drag waited past the first move")
        send(.leftMouseUp, at: CGPoint(x: name.x, y: name.y + 12), hosted.window, hosted.host)

        log.accountDrags = 0
        send(.leftMouseDown, at: name, hosted.window, hosted.host, clickCount: 2)
        send(.leftMouseDragged, at: CGPoint(x: name.x, y: name.y + 12), hosted.window, hosted.host, clickCount: 2)
        XCTAssertGreaterThan(log.accountDrags, 0, "a drag on the second click didn't lift the account")
        send(.leftMouseUp, at: CGPoint(x: name.x, y: name.y + 12), hosted.window, hosted.host, clickCount: 2)

        XCTAssertEqual(log.metricDrags, 0)
        XCTAssertNil(hosted.renaming.edit, "a drag on the name started a rename")
    }

    private func storedAccount(label: String) -> (AccountRenameStore, Provider) {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let stored = accounts.add(kind: .claude, label: label, credential: .apiKey("key"))
        let provider = Provider(id: stored.cardID, kind: .claude, accountLabel: label)
        return (AccountRenameStore(accounts: accounts), provider)
    }

    private func hostWithRenaming(log: Log, lines: [DashboardLine]? = nil) -> Hosted {
        let (renaming, provider) = storedAccount(label: "Personal")
        let family = DashboardFamily(id: "claude", provider: provider, accounts: [account(provider, lines: lines), account(work)])
        let view = DashboardProviderSection(family: family) { account in
            VStack(alignment: .leading, spacing: 0) {
                DashboardAccountCaption(account: account, plan: "Max 5x")
                    .highPriorityGesture(DragGesture(minimumDistance: 4).onChanged { _ in log.accountDrags += 1 })
                ForEach(account.lines) { line in
                    DashboardLiveRow(line: line, onToggleMeterStyle: { log.styleFlips += 1 }, onToggleResetDisplay: { log.resetFlips += 1 })
                        .highPriorityGesture(DragGesture(minimumDistance: 4).onChanged { _ in log.metricDrags += 1 })
                }
            }
        }
        let (window, host) = hostView(view, renaming: renaming)
        return Hosted(window: window, host: host, renaming: renaming, accountID: provider.id)
    }

    private func hostView(_ content: some View, renaming: AccountRenameStore) -> (NSWindow, NSView) {
        let view = content
            .frame(width: PanelMetrics.width - 2 * PanelMetrics.margin)
            .environment(renaming)
            .environment(\.colorScheme, .light)
        return show(view)
    }
}

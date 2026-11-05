import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class DashboardLiveLayoutTests: QuietWindowTestCase {
    private final class Frames {
        var byID: [String: CGRect] = [:]
    }

    private func hostList(_ container: AppContainer) -> (window: NSWindow, host: NSView, frames: Frames) {
        let frames = Frames()
        let view = WidgetGroupedListView(reorderSpaceName: "test", reorderLift: .constant(nil))
            .coordinateSpace(name: "test")
            .onPreferenceChange(ReorderFramePreferenceKey.self) { frames.byID = $0 }
            .frame(width: PanelMetrics.width - 2 * PanelMetrics.margin)
            .environment(container)
            .environment(container.layout)
            .environment(container.dataStore)
            .environment(container.renaming)
            .environment(container.popover)
            .environment(\.colorScheme, .light)
        let (window, host) = show(view)
        return (window, host, frames)
    }

    func testCachedHistoryFigureOpensAndUpdatesItsPopoverWhenDetailsArrive() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let account = accounts.add(kind: .codex, label: "Personal", credential: .apiKey("unused"))
        let snapshot = ProviderSnapshot(
            providerID: account.cardID, displayName: "ChatGPT",
            lines: [.values(label: "Yesterday", values: [MetricValue(number: 766_600_000, kind: .count, label: "tokens")])]
        )
        ProviderSnapshotCache(userDefaults: defaults).save([account.cardID: snapshot])
        let now = snapshot.refreshedAt
        let calendar = Calendar.utc
        let yesterday = try XCTUnwrap(UsageHistory.dayStarts([1], now: now, calendar: calendar).first)
        let day = UsageDay(
            totals: UsageTotals(values: [.tokens: 766_600_000, .inputTokens: 700_000_000, .outputTokens: 66_600_000, .turns: 100]),
            byModel: ["gpt-6-astra": UsageTotals(values: [.turns: 60]), "gpt-6.1-sol": UsageTotals(values: [.turns: 40])]
        )
        var refreshed = snapshot
        let history = UsageHistory(calendar: calendar, asOf: now, days: [yesterday: day])
        refreshed.usageBreakdowns = ["yesterday": try XCTUnwrap(UsageBreakdown(.yesterday, in: history))]

        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults)
        let outcome = await container.dataStore.refresh(providerID: account.cardID)
        XCTAssertEqual(outcome, .cacheHit)
        let (window, host, frames) = hostList(container)
        defer { HoverPopoverState.dismissAll() }
        let rowID = "\(account.cardID).yesterday"
        try await waitUntil { frames.byID[rowID] != nil }
        let row = try XCTUnwrap(frames.byID[rowID])
        let shown = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        func detail() -> NSWindow? { NSApp.windows.first { $0.isVisible && !shown.contains(ObjectIdentifier($0)) } }

        try hover(CGPoint(x: row.maxX - 12, y: row.midY), window, host)
        try await waitUntil { detail() != nil }
        let opened = try XCTUnwrap(detail())
        let savedHeight = opened.frame.height
        container.dataStore.snapshots[account.cardID] = refreshed
        // The new token mix and model list must appear in the open window without moving the pointer.
        try await waitUntil { opened.frame.height > savedHeight + 10 }
        XCTAssertTrue(opened.isVisible)
    }

    func testDefaultNamedSiblingAccountsCanBeReorderedByTheirCaptions() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let personal = accounts.add(kind: .claude, label: "Claude", credential: .apiKey("first"))
        let work = accounts.add(kind: .claude, label: "Work", credential: .apiKey("second"))
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults)
        for account in [personal, work] {
            container.dataStore.snapshots[account.cardID] = ProviderSnapshot(
                providerID: account.cardID, displayName: "Claude", lines: [.percent("Weekly", 30)]
            )
        }
        let (window, host, frames) = hostList(container)
        let firstRowID = "\(personal.cardID).weekly"
        try await waitUntil { frames.byID[firstRowID] != nil && frames.byID[work.cardID] != nil }
        let first = try XCTUnwrap(frames.byID[personal.cardID])
        let row = try XCTUnwrap(frames.byID[firstRowID])
        let target = try XCTUnwrap(frames.byID[work.cardID])
        XCTAssertGreaterThan(row.minY, first.minY, "There is no caption to drag")
        let start = CGPoint(x: first.minX + 10, y: (first.minY + row.minY) / 2)
        let end = CGPoint(x: target.minX + 10, y: target.midY)
        send(.leftMouseDown, at: start, window, host)
        send(.leftMouseDragged, at: CGPoint(x: start.x + 6, y: start.y), window, host)
        send(.leftMouseDragged, at: end, window, host)
        send(.leftMouseUp, at: end, window, host)
        try await waitUntil { container.layout.orderedProviderIDs() == [work.cardID, personal.cardID] }
        XCTAssertNil(container.renaming.edit)
    }

    func testTheProviderHeaderCopiesTheDashboardCardAsPNG() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let account = accounts.add(kind: .claude, label: "Personal", credential: .apiKey("unused"))
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults)
        container.dataStore.snapshots[account.cardID] = ProviderSnapshot(
            providerID: account.cardID, displayName: "Claude", lines: [.percent("Weekly", 30)]
        )
        let (window, host, frames) = hostList(container)
        try await waitUntil { frames.byID[account.cardID] != nil }
        let button = copyButton(in: host.bounds)
        let original = try pixels(of: host)
        try hover(CGPoint(x: button.midX, y: button.midY), window, host)
        try await waitUntil {
            guard let image = try? self.pixels(of: host) else { return false }
            return image != original
        }

        let clipboard = Clipboard.save()
        defer { clipboard.restore() }
        click(CGPoint(x: button.midX, y: button.midY), window, host)
        try await waitUntil { container.popover.shareNotice.value }
        let data = try XCTUnwrap(NSPasteboard.general.data(forType: .png))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertGreaterThan(image.pixelsWide, 0)
        XCTAssertEqual(image.pixelsWide % Int(ShareCardView.width), 0)
    }

    func testTheCopyButtonShowsBesideTheLogoWhileThePointerIsOverItsProvider() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let claude = accounts.add(kind: .claude, label: "Personal", credential: .apiKey("first"))
        let codex = accounts.add(kind: .codex, label: "Personal", credential: .apiKey("second"))
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults)
        for account in [claude, codex] {
            container.dataStore.snapshots[account.cardID] = ProviderSnapshot(
                providerID: account.cardID, displayName: account.kind.rawValue, lines: [.percent("Weekly", 30)]
            )
        }
        let (window, host, frames) = hostList(container)
        let claudeRowID = "\(claude.cardID).weekly", codexRowID = "\(codex.cardID).weekly"
        try await waitUntil { frames.byID[claudeRowID] != nil && frames.byID[codexRowID] != nil }
        let claudeRow = try XCTUnwrap(frames.byID[claudeRowID]), codexRow = try XCTUnwrap(frames.byID[codexRowID])
        func section(holding row: CGRect) throws -> CGRect {
            try XCTUnwrap(frames.byID.first { $0.key.hasPrefix("family:") && $0.value.contains(row.origin) }?.value)
        }
        let claudeSection = try section(holding: claudeRow), codexSection = try section(holding: codexRow)
        let button = copyButton(in: claudeSection), codexButton = copyButton(in: codexSection)
        let logo = CGRect(x: button.maxX + Theme.Spacing.s, y: button.minY, width: button.width, height: button.height)
        let title = CGRect(x: claudeSection.minX, y: claudeSection.minY, width: button.minX - claudeSection.minX,
                           height: DashboardGrid.headerHeight)
        let resting = try pixels(of: host)
        func changed(_ rect: CGRect) -> Bool { (try? self.crop(self.pixels(of: host), rect, in: host)) != (try? self.crop(resting, rect, in: host)) }

        try hover(CGPoint(x: claudeRow.minX + 20, y: claudeRow.midY), window, host)
        try await waitUntil { changed(button) }
        XCTAssertFalse(changed(logo), "The copy button covered the logo")
        XCTAssertFalse(changed(title), "The header moved when the button showed")

        move(CGPoint(x: codexRow.minX + 20, y: codexRow.midY), window, host)
        try await waitUntil { changed(codexButton) && !changed(button) }
    }

    /// The copy button's slot, left of the logo in the header of the section that fills `frame`.
    private func copyButton(in frame: CGRect) -> CGRect {
        let side = DashboardGrid.iconSize
        return CGRect(x: frame.maxX - DashboardGrid.cardPadding - side - Theme.Spacing.s - side,
                      y: frame.minY + (DashboardGrid.headerHeight - side) / 2, width: side, height: side)
    }

    private func crop(_ png: Data, _ rect: CGRect, in host: NSView) throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(data: png)?.cgImage)
        let scale = CGFloat(image.width) / host.bounds.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        let cropped = try XCTUnwrap(image.cropping(to: pixels))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]))
    }
}

private struct Clipboard {
    let items: [[(NSPasteboard.PasteboardType, Data)]]

    static func save() -> Clipboard {
        Clipboard(items: (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        })
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { data in
            let item = NSPasteboardItem()
            for (type, bytes) in data { item.setData(bytes, forType: type) }
            return item
        })
    }
}

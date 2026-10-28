import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The copy button on a provider's dashboard header: nothing at rest, revealed at the header's
/// trailing edge while the pointer rests on the header, gone once it leaves. A click on it copies the
/// card once and starts no drag; the header still drags the provider. Only the dashboard gives its
/// header the button: the share image and the drag previews build the section without one.
@MainActor
final class DashboardCopyButtonTests: QuietWindowTestCase {
    private final class Log {
        var copies = 0
        var headerDrags = 0
    }

    private let provider = Provider(id: "claude@1", displayName: "Claude", icon: "claude", accountLabel: "Personal")
    private let lines: [DashboardLine] = ["Session", "Weekly"].map { title in
        var data = WidgetData(title: title, kind: .percent, used: 30, limit: 100)
        data.resetsAt = Date().addingTimeInterval(3 * 3600)
        return DashboardLine(descriptor: WidgetDescriptor(id: title, providerID: "claude", metricLabel: title, sample: data), data: data)
    }

    private let headerMid = DashboardGrid.headerHeight / 2
    /// A point on the header's name, which starts 8 pt after the logo.
    private let nameX = DashboardGrid.cardPadding + DashboardGrid.inset + DashboardGrid.iconSize + DashboardGrid.columnGap + 10
    /// The header's trailing 16 pt, inside its padding: the button's slot, ending where the rows' resets end.
    private let slot = (DashboardGrid.cardWidth - DashboardGrid.cardPadding - DashboardGrid.inset - 16)..<(DashboardGrid.cardWidth - DashboardGrid.cardPadding - DashboardGrid.inset)

    private func family() -> DashboardFamily {
        DashboardFamily(id: "claude", provider: provider, accounts: [DashboardAccount(provider: provider, lines: lines)])
    }

    private func inkInSlot(_ host: NSView) -> Int {
        InkMap(of: host).count(x: slot, y: 0..<DashboardGrid.headerHeight)
    }

    func testTheHeaderRevealsTheButtonOnHoverAndAClickOnItCopiesOnce() throws {
        let log = Log()
        let section = DashboardProviderSection(family: family()) {
            DashboardProviderHeader(provider: provider, onCopyScreenshot: { log.copies += 1; return true })
                .highPriorityGesture(DragGesture(minimumDistance: 4).onChanged { _ in log.headerDrags += 1 })
        } account: { account in
            DashboardAccountRows(account: account, plan: "Max 5x")
        }
        let (window, host) = hostView(section)
        let button = CGPoint(x: slot.lowerBound + 8, y: headerMid)

        XCTAssertEqual(inkInSlot(host), 0, "the button shows at rest")
        try hover(CGPoint(x: nameX, y: headerMid), window, host)
        XCTAssertGreaterThan(inkInSlot(host), 0, "resting the pointer on the header reveals no button")
        XCTAssertEqual(log.copies, 0, "revealing the button copied")
        try leave(window, host)
        XCTAssertEqual(inkInSlot(host), 0, "the button stays after the pointer leaves")

        try hover(button, window, host)
        click(button, window, host)
        XCTAssertEqual(log.copies, 1, "a click on the button didn't copy")
        XCTAssertEqual(log.headerDrags, 0, "the click dragged the provider")
        click(CGPoint(x: nameX, y: headerMid), window, host)
        XCTAssertEqual(log.copies, 1, "a click on the name copied")
        drag(from: CGPoint(x: host.bounds.width / 2, y: headerMid), window, host)
        XCTAssertGreaterThan(log.headerDrags, 0, "the header no longer drags the provider")
        XCTAssertEqual(log.copies, 1, "the drag copied")
    }

    /// The share image and the drag previews build the section without a copy action, and that
    /// header draws nothing at its trailing edge, under the pointer as at rest.
    func testAHeaderWithoutACopyActionHasNoButton() throws {
        let section = DashboardProviderSection(family: family()) { account in
            DashboardAccountRows(account: account, plan: "Max 5x")
        }
        let (window, host) = hostView(section)

        XCTAssertEqual(inkInSlot(host), 0)
        try hover(CGPoint(x: nameX, y: headerMid), window, host)
        XCTAssertEqual(inkInSlot(host), 0, "a header without a copy action revealed a button")
    }

    /// On the dashboard, the button copies what the menu's Share Screenshot copies, through the same
    /// path: the provider's share card lands on the clipboard as a PNG and the Copied pill shows.
    func testTheDashboardsButtonCopiesTheShareCard() async throws {
        let defaults = isolatedDefaults()
        let descriptor = WidgetDescriptor(
            id: "claude@1.session", providerID: provider.id, metricLabel: "Session",
            sample: WidgetData(title: "Session", kind: .percent, used: 0, limit: 100)
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        let container = AppContainer.forTesting(accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), defaults: defaults)
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        let dataStore = WidgetDataStore.forTesting([], registry: registry, defaults: defaults)
        dataStore.snapshots[provider.id] = ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName, plan: "Max 5x",
            lines: [.progress(label: "Session", used: 30, limit: 100, format: .percent, resetsAt: Date().addingTimeInterval(3600), periodDurationMs: 5 * 3_600_000)]
        )
        let dashboard = WidgetGroupedListView(reorderSpaceName: "test", reorderLift: .constant(nil))
            .coordinateSpace(name: "test")
            .environment(container)
            .environment(layout)
            .environment(dataStore)
            .environment(container.renaming)
        let (window, host) = hostView(dashboard)
        let clipboard = Clipboard.save()
        addTeardownBlock { clipboard.restore() }
        XCTAssertFalse(layout.shareConfirmation)

        let button = CGPoint(x: slot.lowerBound + 8, y: headerMid)
        try hover(button, window, host)
        click(button, window, host)

        XCTAssertTrue(layout.shareConfirmation, "the button's copy didn't raise the Copied pill")
        let png = try XCTUnwrap(NSPasteboard.general.data(forType: .png), "no PNG on the clipboard")
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(CGFloat(image.pixelsWide), ShareCardView.width * ShareCardRenderer.scale, "the clipboard holds something other than the share card")
    }

    /// `content` at the card's width in the dashboard's own panel, offscreen, taking pointer events.
    private func hostView(_ content: some View) -> (NSWindow, NSView) {
        let view = content
            .frame(width: DashboardGrid.cardWidth)
            .environment(AccountRenameStore?.none)
            .environment(\.colorScheme, .light)
        return show(view)
    }
}

/// The general pasteboard's data, put back after a test that copies.
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

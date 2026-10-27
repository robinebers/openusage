import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// The Accounts list with nothing in it says so: a "No Accounts" line in the system's empty-state style
/// where the card would be. The first account fills the card and the line goes.
@MainActor
final class AccountListEmptyStateTests: QuietWindowTestCase {
    func testAnEmptyListReadsNoAccountsUntilAnAccountIsAdded() async throws {
        let defaults = isolatedDefaults()
        let container = await AppContainer.forTesting(
            accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()),
            defaults: defaults
        )
        let list = host(
            AccountListView(reorderSpaceName: "reorder", reorderLift: .constant(nil), frameStore: ReorderFrameStore())
                .environment(container)
                .environment(container.layout)
                .environment(container.renaming)
        )
        let noAccounts = host(ContentUnavailableView { Label("No Accounts", systemImage: "person.crop.circle") })
        XCTAssertEqual(list.bounds.size, noAccounts.bounds.size)
        XCTAssertEqual(try pixels(of: list), try pixels(of: noAccounts), "the empty list doesn't draw the No Accounts state")

        _ = container.accounts.add(kind: .claude, label: "Personal", credential: .apiKey("key"))
        try await Task.sleep(for: .milliseconds(300))
        list.frame.size = list.fittingSize
        XCTAssertEqual(container.layout.orderedProviders().map(\.accountLabel), ["Personal"])
        XCTAssertNotEqual(try pixels(of: list), try pixels(of: noAccounts), "the list still draws the No Accounts state")
    }

    /// `content` at the panel's width in an offscreen window, sized to what it asks for.
    private func host(_ content: some View) -> NSView {
        let host = NSHostingView(rootView: content.frame(width: PanelMetrics.width).environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = QuietWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        QuietTestProcess.show(window, in: self)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The host's pixels as drawn now.
    private func pixels(of host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

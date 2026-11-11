import AppKit
import Security
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class HubRemovalTests: QuietWindowTestCase {
    private final class LockedHubKeys: HubKeyVault, @unchecked Sendable {
        let keys = InMemoryHubKeyVault()
        func load(_ hubID: UUID) throws -> HubKey? { try keys.load(hubID) }
        func save(_ key: HubKey, for hubID: UUID) throws { try keys.save(key, for: hubID) }
        func delete(_ hubID: UUID) throws { throw KeychainVaultError.status(errSecInteractionNotAllowed) }
    }

    func testAFailedHubRemovalStaysOnTheHubsPageAndSaysWhy() async throws {
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface") }
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault(), hubKeys: LockedHubKeys())
        let hub = CLIProxyHub(url: try XCTUnwrap(URL(string: "http://mac-mini.local:8317")))
        try store.addHub(hub, key: "key")
        let offline = RoutingHTTPClient { _ in throw URLError(.cannotConnectToHost) }
        let container = AppContainer.forTesting(accounts: store, defaults: defaults, http: offline)
        container.popover.customizeHubID = hub.id
        let page = HubDetailView(hubID: hub.id)
            .frame(width: PanelMetrics.width)
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
        let (window, host) = show(page, in: .titled, size: CGSize(width: PanelMetrics.width, height: 320))

        func labelled(in element: Any) -> [(text: String, node: NSObject)] {
            guard let node = element as? NSObject else { return [] }
            let text = node.value(forKey: "accessibilityValue") as? String ?? node.value(forKey: "accessibilityLabel") as? String
            return (text.map { [($0, node)] } ?? []) + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(labelled)
        }
        func buttons(in view: NSView) -> [NSButton] { ([view as? NSButton].compactMap { $0 }) + view.subviews.flatMap(buttons) }

        try await waitUntil { labelled(in: host).contains { $0.text == "Remove Hub…" } }
        let remove = try XCTUnwrap(labelled(in: host).first { $0.text == "Remove Hub…" }?.node)
        _ = remove.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await waitUntil { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let confirm = try XCTUnwrap(buttons(in: try XCTUnwrap(sheet.contentView)).first { $0.title.hasPrefix("Remove Hub and") })
        confirm.performClick(nil)

        let reason = try XCTUnwrap(store.lastError)
        try await waitUntil { labelled(in: host).contains { $0.text.contains(reason) } }
        XCTAssertEqual(store.hubs.map(\.id), [hub.id], "the hub stays listed")
        XCTAssertEqual(container.popover.customizeHubID, hub.id, "the page stays open")
    }
}

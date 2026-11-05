import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PopoverFooterTests: QuietWindowTestCase {
    /// As in 0.7, the footer's left side reads on two lines: the app and its version, then the refresh countdown.
    func testTheVersionSitsOverTheNextUpdate() async throws {
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface") }
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        store.add(kind: .claude, label: "Personal", credential: .apiKey("key"))
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        let footer = PopoverFooter(screen: .dashboard)
            .frame(width: PanelMetrics.width)
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(UpdaterController())
        let (window, host) = show(footer)
        defer { window.close() }
        func labelled(in element: Any) -> [(text: String, frame: NSRect)] {
            guard let node = element as? NSObject else { return [] }
            let text = node.value(forKey: "accessibilityValue") as? String ?? node.value(forKey: "accessibilityLabel") as? String
            let frame = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
            let own = text.flatMap { text in frame.map { (text, $0) } }.map { [$0] } ?? []
            return own + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(labelled)
        }
        let versionText = "OpenUsage \(AppInfo.version)"
        func frame(_ match: (String) -> Bool) -> NSRect? { labelled(in: host).first { match($0.text) }?.frame }
        try await waitUntil { frame { $0 == versionText } != nil && frame { $0.hasPrefix("Next update in") } != nil }
        let version = try XCTUnwrap(frame { $0 == versionText })
        let nextUpdate = try XCTUnwrap(frame { $0.hasPrefix("Next update in") })
        XCTAssertGreaterThanOrEqual(version.minY, nextUpdate.maxY - 1, "the version is the first line, above the countdown")
        XCTAssertEqual(version.minX, nextUpdate.minX, accuracy: 1, "both lines start at the same edge")
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class NotificationSettingsTests: QuietWindowTestCase {
    override func setUp() {
        super.setUp()
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
    }

    override func tearDown() {
        NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface")
        super.tearDown()
    }

    func testOneClickOpensTheAppsNotificationSettings() async throws {
        var opened: [URL] = []
        let settings = SettingsScreen(openURL: { opened.append($0) })
        let (window, host) = show(settings.notificationSettingsButton, size: CGSize(width: 400, height: 40))
        defer { window.close() }
        try await waitUntil { self.buttons(in: host).count == 1 }
        let button = try XCTUnwrap(buttons(in: host).first)
        let frame = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )!)
        }
        let expected = try XCTUnwrap(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier!)"))
        XCTAssertEqual(opened, [expected])
    }

    private func buttons(in element: Any) -> [NSObject] {
        guard let node = element as? NSObject else { return [] }
        let own = node.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue ? [node] : []
        return own + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(buttons)
    }
}

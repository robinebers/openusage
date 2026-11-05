import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class NotificationSettingsNoteTests: QuietWindowTestCase {
    override func setUp() {
        super.setUp()
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
    }

    override func tearDown() {
        NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface")
        super.tearDown()
    }

    func testClickingSystemSettingsOpensTheRunningAppsNotificationSettings() async throws {
        for bundleIdentifier in ["com.robinebers.openusage", "com.robinebers.openusage.dev"] {
            var opened: [URL] = []
            var dismissals = 0
            let note = NotificationSettingsNote(bundleIdentifier: bundleIdentifier, openSettings: {
                opened.append($0)
            }, dismissPopover: { dismissals += 1 })
            let (window, host) = show(note, size: CGSize(width: 400, height: 40))
            defer { window.close() }
            try await waitUntil { self.buttons(in: host).count == 1 }
            let button = try XCTUnwrap(buttons(in: host).first)
            let expected = try XCTUnwrap(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)"))
            try click(button, in: window)
            try await waitUntil { dismissals == 1 }
            XCTAssertEqual(opened, [expected], "one click must open this build's app-specific notification settings")
            XCTAssertEqual(dismissals, 1, "the panel must get out of the way of System Settings")
        }
    }

    func testRepeatedClicksWhileSettingsLaunchesSendOnlyOneRequest() async throws {
        let launch = AsyncStream<Void>.makeStream()
        defer { launch.continuation.finish() }
        var launches = 0
        var dismissals = 0
        let note = NotificationSettingsNote(bundleIdentifier: "com.robinebers.openusage", openSettings: { _ in
            launches += 1
            for await _ in launch.stream { break }
        }, dismissPopover: { dismissals += 1 })
        let (window, host) = show(note, size: CGSize(width: 400, height: 40))
        defer { window.close() }
        try await waitUntil { self.buttons(in: host).count == 1 }
        let button = try XCTUnwrap(buttons(in: host).first)
        try click(button, in: window)
        try await waitUntil { launches == 1 }
        try click(button, in: window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(launches, 1, "extra clicks must not queue more launches")
        XCTAssertEqual(dismissals, 0, "keep the panel available if opening System Settings fails")
        launch.continuation.yield(())
        try await waitUntil { dismissals == 1 }
        XCTAssertEqual(launches, 1)
    }

    private func click(_ button: NSObject, in window: NSWindow) throws {
        let frame = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )!)
        }
    }

    private func buttons(in element: Any) -> [NSObject] {
        guard let node = element as? NSObject else { return [] }
        let own = node.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue ? [node] : []
        return own + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(buttons)
    }
}

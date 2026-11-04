import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI
import XCTest
@testable import OpenUsage

/// Settings stays mounted offscreen after its first visit, so its shortcut recorder sits in the
/// panel's key-view loop on every screen. AppKit can hand it focus without a click, and a focused
/// recorder records the next key press as the global shortcut.
@MainActor
final class ShortcutRecorderFocusGuardTests: QuietWindowTestCase {
    private static let name = KeyboardShortcuts.Name("shortcutRecorderFocusGuardTests")

    override func setUp() {
        super.setUp()
        let saved = KeyboardShortcuts.getShortcut(for: .togglePopover)
        KeyboardShortcuts.setShortcut(nil, for: .togglePopover)
        addTeardownBlock { @MainActor in
            KeyboardShortcuts.setShortcut(saved, for: .togglePopover)
            KeyboardShortcuts.setShortcut(nil, for: Self.name)
        }
    }

    func testTheRecorderTakesFocusOnlyWhileSettingsIsShown() async throws {
        let (container, window, host) = try await showSettings(on: .dashboard)
        let recorder = try XCTUnwrap(Self.find(KeyboardShortcuts.RecorderCocoa.self, in: host))
        XCTAssertFalse(window.makeFirstResponder(recorder), "the parked recorder took focus")

        container.popover.screen = .settings
        try await waitUntil { recorder.isEnabled }
        XCTAssertTrue(window.makeFirstResponder(recorder))
        XCTAssertNotNil(recorder.currentEditor())
        window.makeFirstResponder(nil)
    }

    func testCommandCommaOpensSettingsWhenTheParkedRecorderHoldsFocus() async throws {
        let (container, window, host) = try await showSettings(on: .settings)
        let recorder = try XCTUnwrap(Self.find(KeyboardShortcuts.RecorderCocoa.self, in: host))
        XCTAssertTrue(window.makeFirstResponder(recorder))
        container.popover.screen = .dashboard
        try await waitUntil { !recorder.isEnabled }

        NSApp.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: UInt16(kVK_ANSI_Comma)
        )!)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: .togglePopover), "⌘, was recorded as the global shortcut")
        XCTAssertEqual(container.popover.screen, .settings, "⌘, didn't open Settings")
        XCTAssertNil(recorder.currentEditor())
    }

    func testClearingStrayFocusDropsTheRecorderButKeepsATextField() throws {
        let (window, host) = show(VStack {
            KeyboardShortcuts.Recorder(for: Self.name)
            TextField("Name", text: .constant(""))
        }.padding())
        let panel = try XCTUnwrap(window as? MenuBarPanel)
        let recorder = try XCTUnwrap(Self.find(KeyboardShortcuts.RecorderCocoa.self, in: host))
        let field = try XCTUnwrap(Self.find(NSTextField.self, in: host) { !($0 is NSSearchField) })

        XCTAssertTrue(panel.makeFirstResponder(recorder))
        panel.clearStrayFocus()
        XCTAssertNil(recorder.currentEditor(), "the recorder kept focus")
        XCTAssertFalse(panel.firstResponder is NSText)

        XCTAssertTrue(panel.makeFirstResponder(field))
        panel.clearStrayFocus()
        XCTAssertTrue(panel.firstResponder is NSText, "a text field lost focus while editing")
        panel.makeFirstResponder(nil)
    }

    private func showSettings(on screen: PopoverScreen) async throws -> (AppContainer, NSWindow, NSView) {
        let defaults = isolatedDefaults()
        let container = AppContainer.forTesting(accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), defaults: defaults)
        container.popover.screen = screen
        container.popover.settingsTab = .general
        let (window, host) = show(ZStack {
            PopoverKeyReader { key in
                if key == .settings { container.popover.toggle(.settings) }
                return true
            }
            SettingsScreen()
        }
            .defaultAppStorage(defaults)
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(UpdaterController()),
            size: CGSize(width: PanelMetrics.width, height: 500))
        try await Task.sleep(for: .milliseconds(300))
        return (container, window, host)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView, where matches: (T) -> Bool = { _ in true }) -> T? {
        if let match = view as? T, matches(match) { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview, where: matches) { return match }
        }
        return nil
    }
}

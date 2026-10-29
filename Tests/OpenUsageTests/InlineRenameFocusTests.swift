import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class InlineRenameFocusTests: QuietWindowTestCase {
    private struct Hosted {
        let panel: MenuBarPanel
        let host: NSView
        let container: AppContainer
        let accounts: [String: String]
    }

    func testDoubleClickingAnAccountNameTakesTheKeyboard() async throws {
        let hosted = try await host()
        try await resignKey(hosted)
        let caption = PanelMetrics.margin + DashboardGrid.headerHeight + DashboardGrid.headerGap
            + DashboardGrid.cardPadding + DashboardGrid.captionHeight / 2
        try await doubleClick(CGPoint(x: PanelMetrics.margin + DashboardGrid.cardPadding + DashboardGrid.inset + 10, y: caption), hosted)
        try await assertRenameTakesTyping("Personal", hosted)
    }

    func testRenameFromTheMenuTakesTheKeyboard() async throws {
        let hosted = try await host()
        try await resignKey(hosted)
        hosted.container.renaming.begin(try XCTUnwrap(hosted.accounts["Work"]))
        try await assertRenameTakesTyping("Work", hosted)
    }

    func testClickingTheAccountsTitleTakesTheKeyboard() async throws {
        let hosted = try await host(accountsTitle: "Work")
        try await resignKey(hosted)
        let title = CGPoint(x: hosted.host.bounds.width / 2, y: 22)
        try await send(.leftMouseDown, at: title, hosted)
        try await send(.leftMouseUp, at: title, hosted)
        try await assertRenameTakesTyping("Work", hosted)
    }

    private func assertRenameTakesTyping(
        _ name: String, _ hosted: Hosted, line: UInt = #line
    ) async throws {
        try await Task.sleep(for: .milliseconds(500))
        let renaming = hosted.container.renaming
        XCTAssertEqual(renaming.edit?.providerID, hosted.accounts[name], "no rename opened", line: line)
        XCTAssertTrue(hosted.panel.isKeyWindow, "the panel isn't key, so keystrokes go elsewhere", line: line)
        let editor = try XCTUnwrap(hosted.panel.firstResponder as? NSTextView, "the rename field doesn't have focus", line: line)
        XCTAssertEqual(editor.string, name, line: line)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (name as NSString).length), "the whole name isn't selected", line: line)

        for character in "Zed" {
            try await press(String(character), hosted)
        }
        XCTAssertEqual(renaming.draft, "Zed", "typing didn't replace the name", line: line)
        renaming.cancel()
    }

    private func host(accountsTitle: String? = nil) async throws -> Hosted {
        try QuietTestProcess.requireFocus()
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        var accounts: [String: String] = [:]
        for label in ["Personal", "Work"] {
            accounts[label] = store.add(kind: .claude, label: label, credential: .apiKey("key")).cardID
        }
        for _ in 0..<200 where container.layout.displayGroups.count < accounts.count {
            try await Task.sleep(for: .milliseconds(5))
        }

        let hosting = NSHostingView(rootView: AnyView(
            DashboardView()
                .reduceAnimationsWhenRequested()
                .environment(container)
                .environment(container.layout)
                .environment(container.popover)
                .environment(container.dataStore)
                .environment(container.renaming)
                .environment(UpdaterController())
                .environment(\.colorScheme, .light)
        ))
        let frame = NSRect(x: -20_000, y: -20_000, width: PanelMetrics.width, height: 400)
        let panel = MenuBarPanel(contentRect: frame)
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.host(hosting)
        panel.setFrame(frame, display: false)
        container.popover.popoverShown = true
        panel.makeKeyAndOrderFront(nil)
        addTeardownBlock { panel.close() }
        try await Task.sleep(for: .milliseconds(800))
        if let accountsTitle {
            container.popover.customizeProviderID = accounts[accountsTitle]
            container.popover.screen = .accounts
            try await Task.sleep(for: .milliseconds(1200))
        }
        return Hosted(panel: panel, host: hosting, container: container, accounts: accounts)
    }

    private func resignKey(_ hosted: Hosted) async throws {
        NSApp.deactivate()
        for _ in 0..<100 where hosted.panel.isKeyWindow || NSApp.isActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(hosted.panel.isKeyWindow, "precondition: the panel is still key")
    }

    private func doubleClick(_ point: CGPoint, _ hosted: Hosted) async throws {
        try await send(.leftMouseDown, at: point, hosted)
        try await send(.leftMouseUp, at: point, hosted)
        try await send(.leftMouseDown, at: point, hosted, clickCount: 2)
        try await send(.leftMouseUp, at: point, hosted, clickCount: 2)
    }

    private func send(_ type: NSEvent.EventType, at point: CGPoint, _ hosted: Hosted, clickCount: Int = 1) async throws {
        NSApp.sendEvent(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: point.x, y: hosted.host.bounds.height - point.y),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hosted.panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0
        )!)
        try await Task.sleep(for: .milliseconds(40))
    }

    /// A key press as the window server delivers it: to the key window, or nowhere when there is none,
    /// so it reaches the field only when the panel is key.
    private func press(_ character: String, _ hosted: Hosted) async throws {
        guard let keyWindow = NSApp.keyWindow else { return }
        NSApp.sendEvent(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: keyWindow.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        )!)
        try await Task.sleep(for: .milliseconds(30))
    }
}

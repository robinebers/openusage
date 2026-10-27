import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// Every inline rename takes the keyboard at once, in the dashboard's own panel: the panel is key, the
/// field editor is first responder with the whole name selected after SwiftUI's focus has settled, and
/// typing replaces the name. Each case starts with the panel not key, the state it's in after the app
/// deactivates or a menu or popover took key, and drives the panel with real events sent through
/// `NSApp`, so first-mouse handling and key routing are AppKit's own. They make the panel key and the
/// process active, so they run only under `OPENUSAGE_FOCUS_TESTS=1`.
@MainActor
final class InlineRenameFocusTests: QuietWindowTestCase {
    private struct Hosted {
        let panel: MenuBarPanel
        let host: NSView
        let container: AppContainer
        let accounts: [String: String]
    }

    /// A double-click on an account's name on its caption, in a provider with two accounts.
    func testDoubleClickingAnAccountNameTakesTheKeyboard() async throws {
        let hosted = try await host()
        try await resignKey(hosted)
        let caption = PanelMetrics.margin + DashboardGrid.headerHeight + DashboardGrid.headerGap
            + DashboardGrid.cardPadding + DashboardGrid.captionHeight / 2
        try await doubleClick(CGPoint(x: PanelMetrics.margin + DashboardGrid.cardPadding + DashboardGrid.inset + 10, y: caption), hosted)
        try await assertRenameTakesTyping("Personal", hosted)
    }

    /// A double-click on the account's name in a one-account provider's header.
    func testDoubleClickingAOneAccountHeaderTakesTheKeyboard() async throws {
        let hosted = try await host(soleCodex: true)
        try await resignKey(hosted)
        let header = PanelMetrics.margin + DashboardGrid.headerHeight / 2
        // The name follows "Codex — " in the header's type.
        let prefix = ("Codex — " as NSString).size(withAttributes: [.font: DashboardGrid.headerNSFont]).width
        try await doubleClick(CGPoint(x: PanelMetrics.margin + DashboardGrid.cardPadding + DashboardGrid.inset + prefix + 10, y: header), hosted)
        try await assertRenameTakesTyping("Sunstory", hosted)
    }

    /// Right-click → Rename, which begins the edit once the menu has closed.
    func testRenameFromTheMenuTakesTheKeyboard() async throws {
        let hosted = try await host()
        try await resignKey(hosted)
        hosted.container.renaming.begin(try XCTUnwrap(hosted.accounts["Work"]))
        try await assertRenameTakesTyping("Work", hosted)
    }

    /// A click on the Accounts screen's title.
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

    /// The dashboard (or, with `accountsTitle`, that account's Accounts page) as `StatusItemController`
    /// hosts it, for Claude "Personal" and "Work", plus Codex "Sunstory" alone when `soleCodex`.
    private func host(soleCodex: Bool = false, accountsTitle: String? = nil) async throws -> Hosted {
        try QuietTestProcess.requireFocus()
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = await AppContainer.forTesting(accounts: store, defaults: defaults)
        var accounts: [String: String] = [:]
        if soleCodex {
            accounts["Sunstory"] = store.add(kind: .codex, label: "Sunstory", credential: .apiKey("key")).cardID
        } else {
            for label in ["Personal", "Work"] {
                accounts[label] = store.add(kind: .claude, label: label, credential: .apiKey("key")).cardID
            }
        }
        for _ in 0..<200 where container.layout.displayGroups.count < accounts.count {
            try await Task.sleep(for: .milliseconds(5))
        }

        let hosting = NSHostingController(rootView: AnyView(
            DashboardView()
                .reduceAnimationsWhenRequested()
                .environment(container)
                .environment(container.layout)
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
        panel.contentViewController = hosting
        panel.setFrame(frame, display: false)
        container.layout.popoverShown = true
        panel.makeKeyAndOrderFront(nil)
        addTeardownBlock { panel.close() }
        try await Task.sleep(for: .milliseconds(800))
        if let accountsTitle {
            container.layout.customizeProviderID = accounts[accountsTitle]
            container.layout.screen = .accounts
            try await Task.sleep(for: .milliseconds(1200))
        }
        return Hosted(panel: panel, host: hosting.view, container: container, accounts: accounts)
    }

    /// Leaves the panel on screen but not key, as it is once the app deactivates.
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

    /// `point` is top-left based, in the panel's content.
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

import AppKit
import Observation
import SwiftUI
import XCTest
@testable import OpenUsage

/// Cancel, and Escape with it, steps back from a provider's sign-in to the provider list; only on
/// the list does it close the sheet. Return presses Open Browser.
@MainActor
final class AddAccountSheetTests: QuietWindowTestCase {
    func testCancelOnAProviderStepReturnsToTheListAndCancelOnTheListCloses() async throws {
        let defaults = isolatedDefaults()
        let url = try XCTUnwrap(URL(string: "https://example.com/authorize"))
        var opened: [URL] = []
        let flow = AddAccountFlow(store: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), openURL: { opened.append($0) }) { _ in
            SlowLogin(prompt: .browser(url, acceptsPastedCode: false))
        }
        let presentation = SheetPresentation()
        let window = show(SheetHost(presentation: presentation, flow: flow), in: .titled, size: CGSize(width: 400, height: 500)).window
        let sheet = try await waitForSheet(on: window)

        flow.choose(.codex)
        try await waitUntil { flow.prompt != nil }
        XCTAssertEqual(opened, [url], "the browser didn't open on its own")
        try await Task.sleep(for: .milliseconds(300))
        press(keyCode: 36, character: "\r", in: sheet)
        try await waitUntil { opened.count == 2 }
        XCTAssertEqual(opened, [url, url], "Return didn't press Open Browser")

        pressEscape(in: sheet)
        try await waitUntil { flow.provider == nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(flow.selection, .codex)
        XCTAssertNil(flow.prompt)
        XCTAssertFalse(flow.isWorking)
        XCTAssertTrue(presentation.isPresented)
        XCTAssertNotNil(window.attachedSheet, "Cancel on the sign-in step closed the sheet")

        pressEscape(in: sheet)
        try await waitUntil { !presentation.isPresented }
        XCTAssertFalse(presentation.isPresented, "Cancel on the provider list didn't close the sheet")
    }

    func testArrowKeysAndReturnChooseAProvider() async throws {
        let defaults = isolatedDefaults()
        let url = try XCTUnwrap(URL(string: "https://example.com/authorize"))
        let flow = AddAccountFlow(store: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), openURL: { _ in }) { _ in
            SlowLogin(prompt: .browser(url, acceptsPastedCode: false))
        }
        let presentation = SheetPresentation()
        let window = show(SheetHost(presentation: presentation, flow: flow), in: .titled, size: CGSize(width: 400, height: 700)).window
        addTeardownBlock { flow.cancel() }
        let sheet = try await waitForSheet(on: window)

        press(keyCode: 125, character: "\u{F701}", in: sheet)
        press(keyCode: 125, character: "\u{F701}", in: sheet)
        try await waitUntil { flow.selection == .codex }
        XCTAssertNil(flow.provider, "Moving the selection must not choose the provider")

        press(keyCode: 36, character: "\r", in: sheet)
        try await waitUntil { flow.provider == .codex }
        XCTAssertEqual(flow.provider, .codex)
    }

    /// Both sign-in steps, light and dark: the close button sits in the top-right corner and the
    /// sign-in's status is centred under the two buttons. OPENUSAGE_RENDER_DIR, when set, receives
    /// each render as a PNG.
    func testSignInStepsPutTheCloseButtonTopRightAndTheStatusCentredUnderTheButtons() async throws {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let url = try XCTUnwrap(URL(string: "https://example.com/authorize"))
        let steps: [(name: String, provider: ProviderKind, prompt: LoginPrompt)] = [
            ("browser", .claude, .browser(url, acceptsPastedCode: true)),
            ("device-code", .copilot, .deviceCode(userCode: "ABCD-1234", verificationURL: url)),
        ]
        let renderDirectory = ProcessInfo.processInfo.environment["OPENUSAGE_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for step in steps {
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let flow = AddAccountFlow(store: store, openURL: { _ in }) { _ in SlowLogin(prompt: step.prompt) }
                addTeardownBlock { flow.cancel() }
                flow.choose(step.provider)
                try await waitUntil { flow.prompt != nil }
                let host = show(
                    AddAccountSheet(flow: flow).background(Color(nsColor: .windowBackgroundColor)), in: .titled, appearance: appearance
                ).host
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                if let renderDirectory {
                    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                        .write(to: renderDirectory.appendingPathComponent("signin-\(step.name)-\(scheme).png"))
                }
                let label = "\(step.name) \(scheme)"
                let size = host.bounds.size
                XCTAssertEqual(size.width, 300, label)
                let ink = InkMap(rep, size: size)
                XCTAssertGreaterThan(ink.count(x: size.width - 40..<size.width - 10, y: 10..<40), 20, "\(label): no close button in the top-right corner")
                let status = try XCTUnwrap(ink.bounds(y: size.height - 40..<size.height - 18), "\(label): nothing under the buttons")
                XCTAssertEqual(status.midX, size.width / 2, accuracy: 3, "\(label): the status line isn't centred")
                // The sheet hangs from a window that is never key, as the live panel isn't once the
                // browser is up: the primary has to be accent-filled all the same, and only it.
                let buttons = (size.height - 80)..<(size.height - 44)
                XCTAssertGreaterThan(accent(rep, size: size, x: size.width / 2..<size.width - 20, y: buttons), 400, "\(label): the primary button isn't accent-filled")
                XCTAssertEqual(accent(rep, size: size, x: 20..<size.width / 2, y: buttons), 0, "\(label): the secondary button is accent-filled")
            }
        }
    }

    /// Pixels in the region filled with the accent colour: clearly blue, well away from any grey.
    private func accent(_ rep: NSBitmapImageRep, size: CGSize, x: Range<CGFloat>, y: Range<CGFloat>) -> Int {
        let scale = CGFloat(rep.pixelsWide) / size.width
        var count = 0
        for row in Int(y.lowerBound * scale)..<Int(y.upperBound * scale) {
            for column in Int(x.lowerBound * scale)..<Int(x.upperBound * scale) {
                guard let color = rep.colorAt(x: column, y: row) else { continue }
                if color.blueComponent > 0.6, color.blueComponent > color.redComponent + 0.3 { count += 1 }
            }
        }
        return count
    }

    private func press(keyCode: UInt16, character: String, in sheet: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            sheet.sendEvent(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: keyCode == 125 ? [.numericPad, .function] : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode
            )!)
        }
    }

    private func waitForSheet(on window: NSWindow) async throws -> NSWindow {
        try await waitUntil { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(QuietTestProcess.onAScreen(sheet), "the sheet shows on a screen")
        return sheet
    }

    private func pressEscape(in sheet: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            sheet.sendEvent(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
            )!)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the Add Account sheet")
    }
}

@MainActor
@Observable
private final class SheetPresentation {
    var isPresented = true
}

private struct SheetHost: View {
    @Bindable var presentation: SheetPresentation
    let flow: AddAccountFlow

    var body: some View {
        Color.clear
            .sheet(isPresented: $presentation.isPresented) {
                AddAccountSheet(flow: flow)
            }
    }
}

private struct SlowLogin: ProviderLogin {
    let prompt: LoginPrompt

    func login(prompt show: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        await show(prompt)
        try await Task.sleep(for: .seconds(30))
        return ("late", .oauth(OAuthTokens(accessToken: "access")))
    }
}

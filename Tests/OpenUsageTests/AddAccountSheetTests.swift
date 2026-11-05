import AppKit
import Observation
import SwiftUI
import Vision
import XCTest
@testable import OpenUsage

@MainActor
final class AddAccountSheetTests: QuietWindowTestCase {
    func testKeyboardSelectionOpensSignInAndEscapeReturnsToTheListThenCloses() async throws {
        let defaults = isolatedDefaults()
        let url = try XCTUnwrap(URL(string: "https://example.com/authorize"))
        var opened: [URL] = []
        let flow = AddAccountFlow(store: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), openURL: { opened.append($0) }) { _, _, _, _ in
            SlowLogin(prompt: .browser(url, acceptsPastedCode: false))
        }
        let presentation = SheetPresentation()
        let window = show(SheetHost(presentation: presentation, flow: flow), in: .titled, size: CGSize(width: 400, height: 700)).window
        addTeardownBlock { flow.cancel() }
        let sheet = try await waitForSheet(on: window)

        press(keyCode: 125, character: "\u{F701}", in: sheet)
        press(keyCode: 125, character: "\u{F701}", in: sheet)
        try await waitUntil { flow.selection == .provider(.codex) }
        XCTAssertNil(flow.provider, "Moving the selection must not start sign-in")

        press(keyCode: 36, character: "\r", in: sheet)
        try await waitUntil { flow.prompt != nil }
        XCTAssertEqual(opened, [url], "the browser didn't open on its own")
        try await Task.sleep(for: .milliseconds(300))
        press(keyCode: 36, character: "\r", in: sheet)
        try await waitUntil { opened.count == 2 }
        XCTAssertEqual(opened, [url, url], "Return didn't press Open Browser")

        press(keyCode: 53, character: "\u{1b}", in: sheet)
        try await waitUntil { flow.provider == nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(flow.selection, .provider(.codex))
        XCTAssertNil(flow.prompt)
        XCTAssertFalse(flow.isWorking)
        XCTAssertTrue(presentation.isPresented)
        XCTAssertNotNil(window.attachedSheet, "Cancel on the sign-in step closed the sheet")

        press(keyCode: 53, character: "\u{1b}", in: sheet)
        try await waitUntil { !presentation.isPresented }
        XCTAssertFalse(presentation.isPresented, "Cancel on the provider list didn't close the sheet")
    }

    func testAPastedTokenIsMaskedAndAPastedCodeIsNot() async throws {
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault())
        let url = try XCTUnwrap(URL(string: "https://example.com/authorize"))
        let steps: [(provider: ProviderKind, prompt: LoginPrompt, masked: Bool)] = [
            (.devin, .browserToken(url), true),
            (.claude, .browser(url, acceptsPastedCode: true), false),
        ]
        for (provider, prompt, masked) in steps {
            let flow = AddAccountFlow(store: store, openURL: { _ in }) { _, _, _, _ in SlowLogin(prompt: prompt) }
            addTeardownBlock { flow.cancel() }
            flow.choose(provider)
            try await waitUntil { flow.prompt != nil }
            flow.pastedCode = "pasted-secret"
            let host = show(AddAccountSheet(flow: flow), in: .titled).host
            try await waitUntil { textFields(in: host).contains { $0.stringValue == "pasted-secret" } }
            let field = try XCTUnwrap(textFields(in: host).first { $0.stringValue == "pasted-secret" }, "\(provider): no field shows the pasted value")
            XCTAssertEqual(field is NSSecureTextField, masked, "\(provider): the pasted value is \(masked ? "shown in plain text" : "masked")")
        }
    }

    func testTheHubSheetShowsTheHintOrTheErrorButNeverBoth() async throws {
        let hint = "The hub needs remote management turned on. OpenUsage uses https unless you type http://, which works only for this Mac, your local network, or Tailscale."
        let error = "Use https for hub.example.com. OpenUsage uses http only for a hub on this Mac, your local network, or Tailscale."
        let flow = AddAccountFlow(
            store: AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault()), connectHub: { _, _ in throw ProviderError.unavailable(error) }
        )
        flow.chooseHub()
        flow.hubURL = "http://hub.example.com"
        flow.apiKey = "mgmt-key"
        let host = show(AddAccountSheet(flow: flow), in: .titled, appearance: .darkAqua, size: CGSize(width: 420, height: 560)).host
        let messages = { try ["needs remote management", "unencrypted", "Use https for"].filter(self.readText(in: host).contains) }

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try messages(), ["needs remote management"], "an http address shows only the hint")
        flow.connect()
        try await waitUntil { flow.errorMessage != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try messages(), ["Use https for"], "the error replaces the hint")
    }

    private func readText(in host: NSView) throws -> String {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let request = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: XCTUnwrap(rep.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap(textFields(in:))
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

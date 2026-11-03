import AppKit
import os
import SwiftUI
import Vision
import XCTest
@testable import OpenUsage

/// A CLIProxyAPI hub in Accounts is one row that opens its own page, its accounts are listed only there,
/// and any number of hubs live side by side.
@MainActor
final class CLIProxyHubNestingTests: QuietWindowTestCase {
    private func listing(_ prefix: String, _ providers: [String]) -> Data {
        let files = providers.enumerated().map { index, provider in
            #"{"id":"\#(prefix)-\#(index)","auth_index":"\#(prefix)-idx-\#(index)","provider":"\#(provider)","account_type":"oauth","email":"\#(prefix)\#(index)@example.com"}"#
        }
        return Data((#"{"files":["# + files.joined(separator: ",") + "]}").utf8)
    }

    /// Serves each hub's login list by host, and refuses every call to a host in `down`.
    private func hubs(_ listings: [String: Data], down: OSAllocatedUnfairLock<Set<String>> = .init(initialState: [])) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            let host = request.url.host() ?? ""
            if down.withLock({ $0.contains(host) }) { throw URLError(.cannotConnectToHost) }
            return HTTPResponse(statusCode: 200, headers: [:], body: listings[host] ?? Data(#"{"files":[]}"#.utf8))
        }
    }

    func testTwoHubsConnectSyncAndRemoveIndependently() async throws {
        let store = AccountStore(defaults: isolatedDefaults(), vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        let http = hubs(["mac-mini.local": listing("mini", ["claude", "codex", "cursor"]), "hub.example.com": listing("office", ["claude", "devin"])])
        let sync = CLIProxyHubSync(accounts: store, client: CLIProxyHubClient(http: http, gate: CLIProxyHubGate()))

        try await sync.connect(url: "http://mac-mini.local:8317", key: "key-a")
        try await sync.connect(url: "https://hub.example.com", key: "key-b")

        XCTAssertEqual(store.hubs.count, 2)
        let (mini, office) = (store.hubs[0], store.hubs[1])
        XCTAssertEqual(store.accounts(onHub: mini.id).map(\.kind), [.claude, .codex])
        XCTAssertEqual(store.accounts(onHub: office.id).map(\.kind), [.claude, .devin])
        XCTAssertEqual(sync.status(of: mini.id), .synced(unsupported: 1))
        XCTAssertEqual(sync.status(of: office.id), .synced(unsupported: 0))
        XCTAssertEqual(try store.hubKeys.load(mini.id)?.key, "key-a")
        XCTAssertEqual(try store.hubKeys.load(office.id)?.key, "key-b")

        await sync.syncDue(maxAge: 0)
        XCTAssertEqual(store.accounts.count, 4, "reading both hubs again changes nothing")

        sync.remove(mini.id)
        XCTAssertEqual(store.hubs.map(\.id), [office.id])
        XCTAssertEqual(store.accounts.map(\.kind), [.claude, .devin], "only the removed hub's accounts go")
        XCTAssertNil(try store.hubKeys.load(mini.id))
        XCTAssertEqual(try store.hubKeys.load(office.id)?.key, "key-b")
    }

    func testBackGoesFromAHubAccountToItsHubThenToTheAccountsList() {
        let popover = PopoverState()
        popover.openAccounts(nil)
        let hub = UUID()
        popover.customizeHubID = hub
        popover.customizeProviderID = "claude@hub"

        XCTAssertTrue(popover.back())
        XCTAssertNil(popover.customizeProviderID)
        XCTAssertEqual(popover.customizeHubID, hub, "the account goes back to its hub's page")
        XCTAssertTrue(popover.back())
        XCTAssertNil(popover.customizeHubID)
        XCTAssertEqual(popover.screen, .accounts)

        popover.customizeHubID = hub
        popover.openAccounts("claude@1")
        XCTAssertNil(popover.customizeHubID, "an account opened from the dashboard goes back to the list")
        popover.customizeHubID = hub
        popover.screen = .dashboard
        XCTAssertNil(popover.customizeHubID, "leaving Accounts forgets the hub")
    }

    func testAccountsShowsEachHubAsARowAndItsAccountsOnlyOnItsPage() async throws {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault(), hubKeys: InMemoryHubKeyVault())
        _ = store.add(kind: .claude, label: "Personal", credential: .apiKey("key"))
        let down = OSAllocatedUnfairLock<Set<String>>(initialState: [])
        let http = hubs(["mac-mini.local": listing("mini", ["claude", "codex", "cursor"]), "hub.example.com": listing("office", ["devin"])], down: down)
        let container = AppContainer.forTesting(accounts: store, defaults: defaults, http: http)
        try await container.hubs.connect(url: "http://mac-mini.local:8317", key: "key-a")
        try await container.hubs.connect(url: "https://hub.example.com", key: "key-b")
        down.withLock { $0.insert("hub.example.com") }
        await container.hubs.syncDue(maxAge: 0)
        let (mini, office) = (store.hubs[0], store.hubs[1])
        guard case .failed = container.hubs.status(of: office.id) else { return XCTFail("the office hub's read didn't fail") }
        let miniClaude = try XCTUnwrap(store.accounts(onHub: mini.id).first).cardID
        try await waitUntil { container.layout.provider(id: miniClaude) != nil }

        container.popover.openAccounts(nil)
        let list = try await screenText(container)
        for text in ["Personal", "mac-mini.local:8317", "2 accounts", "hub.example.com", "1 account"] {
            XCTAssertTrue(ocrShows(in: list, text), "the list lacks \(text): \(list)")
        }
        XCTAssertFalse(ocrShows(in: list, "mini0@example.com"), "a hub's account is listed only on its hub's page: \(list)")
        XCTAssertFalse(ocrShows(in: list, "Remove Hub"), list)

        container.popover.customizeHubID = mini.id
        let hubPage = try await screenText(container)
        for text in ["mini0@example.com", "mini1@example.com", "1 login OpenUsage doesn", "Replace Management Key", "Remove Hub"] {
            XCTAssertTrue(ocrShows(in: hubPage, text), "the hub's page lacks \(text): \(hubPage)")
        }
        XCTAssertFalse(ocrShows(in: hubPage, "Personal"), hubPage)

        container.popover.customizeHubID = office.id
        let failed = try await screenText(container)
        XCTAssertTrue(ocrShows(in: failed, "reach the CLIProxyAP"), "the failed hub's page says why: \(failed)")
        XCTAssertTrue(ocrShows(in: failed, "office0@example.com"), "its accounts stay listed: \(failed)")

        container.popover.customizeHubID = mini.id
        container.popover.customizeProviderID = miniClaude
        let accountPage = try await screenText(container)
        XCTAssertTrue(ocrShows(in: accountPage, "Managed by mac-mini.local:8317"), accountPage)
    }

    /// Vision sometimes drops the space between words, as in "1account".
    private func ocrShows(in screen: String, _ text: String) -> Bool {
        screen.replacingOccurrences(of: " ", with: "").contains(text.replacingOccurrences(of: " ", with: ""))
    }

    private func screenText(_ container: AppContainer) async throws -> String {
        let view = DashboardView()
            .environment(\.reduceAnimations, true)
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(container.renaming)
            .environment(UpdaterController())
            .environment(\.colorScheme, .light)
        let (window, host) = show(view, in: .borderless, size: CGSize(width: PanelMetrics.width, height: 640))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try pixels(of: host)))
        let image = try XCTUnwrap(bitmap.cgImage)
        let scale = 3
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width * scale, height: image.height * scale, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(context.makeImage())).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

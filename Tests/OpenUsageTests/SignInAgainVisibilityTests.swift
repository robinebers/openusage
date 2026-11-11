import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// An account's page offers Sign In Again while Priority lists the account under Needs Attention, and always
/// for an OpenCode account still on its API key.
@MainActor
final class SignInAgainVisibilityTests: QuietWindowTestCase {
    func testAWorkingAccountsPageHasNoSignInAgain() async throws {
        let page = try await hostPage(signInExpired: false)
        XCTAssertEqual(page.needsAttention, [])
        XCTAssertFalse(page.clickingDownThePageSignsInAgain(), "A working account's page offered Sign In Again.")
    }

    func testAnExpiredSignInsPageOffersSignInAgain() async throws {
        let page = try await hostPage(signInExpired: true)
        XCTAssertEqual(page.needsAttention, [ProviderError.signInExpired(.claude).localizedDescription])
        XCTAssertTrue(page.clickingDownThePageSignsInAgain(), "An account Priority lists under Needs Attention had no Sign In Again.")
    }

    func testAWorkingOpenCodeKeyAccountsPageOffersSignInAgain() async throws {
        let usage = #"{"usage":{"rolling":{"percent":12,"resetsAt":"2026-07-12T13:30:00Z"},"weekly":{"percent":8,"resetsAt":"2026-07-13T00:00:00Z"},"monthly":{"percent":40,"resetsAt":"2026-08-04T11:18:32Z"}}}"#
        let page = try await hostPage(kind: .opencodeGo, credential: .apiKey("key")) { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(usage.utf8))
        }
        XCTAssertEqual(page.needsAttention, [])
        let signedInWithKey = await page.container.signsInWithKey(page.id)
        XCTAssertTrue(signedInWithKey)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(page.clickingDownThePageSignsInAgain(), "An OpenCode account still on its API key had no Sign In Again.")
    }

    @MainActor
    private struct Page {
        let test: SignInAgainVisibilityTests
        let container: AppContainer
        let window: NSWindow
        let host: NSView
        let id: String

        var needsAttention: [String] {
            container.dataStore.priorityBoard(in: container.layout.displayGroups, now: Date()).notices.map(\.message)
        }

        /// Clicks every few points from the top of the page, stopping at the first click that starts Sign In Again.
        func clickingDownThePageSignsInAgain() -> Bool {
            for y in stride(from: 2, to: host.bounds.height, by: 4) {
                test.click(CGPoint(x: 40, y: y), window, host)
                if container.popover.signingInAgainProviderID == id { return true }
            }
            return false
        }
    }

    /// A Claude account's page after one usage read, which Claude refuses when `signInExpired`, along with the renewal.
    private func hostPage(signInExpired: Bool) async throws -> Page {
        try await hostPage(kind: .claude, credential: .oauth(.init(accessToken: "old", refreshToken: "old-r"))) { request in
            if !signInExpired {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":10}}"#.utf8))
            }
            if request.url == ClaudeLogin.tokenURL {
                return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
    }

    private func hostPage(
        kind: ProviderKind,
        credential: AccountCredential,
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) async throws -> Page {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let id = store.add(kind: kind, label: "Personal", credential: credential).cardID
        let http = RoutingHTTPClient(handler: handler)
        let container = AppContainer.forTesting(accounts: store, defaults: defaults, http: http)
        try await waitUntil { container.layout.provider(id: id) != nil }
        container.dataStore.snapshots[id] = ProviderSnapshot(
            providerID: id, displayName: kind.displayName, plan: nil,
            lines: [.progress(label: "Session", used: 10, limit: 100, format: .percent)]
        )
        _ = await container.dataStore.refresh(providerID: id, force: true)
        let view = AccountDetailView(providerID: id, reorderSpaceName: "reorder", reorderLift: .constant(nil), frameStore: ReorderFrameStore())
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
        let (window, host) = show(view, in: .titled, size: CGSize(width: PanelMetrics.width, height: 240))
        return Page(test: self, container: container, window: window, host: host, id: id)
    }
}

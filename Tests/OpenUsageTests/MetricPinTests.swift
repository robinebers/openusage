import XCTest
@testable import OpenUsage

@MainActor
final class MetricPinTests: QuietWindowTestCase {
    func testAPinIsSavedPerAccountAndMetricAndSurvivesARestart() throws {
        let defaults = isolatedDefaults()
        let oldStars: [String: Any] = [
            "pinnedMetricIDs": ["claude.session"],
            "providerOrder": ["claude", "codex", "cursor"],
            "metricOrderByProvider": [String: [String]](),
            "seededProviderIDs": ["claude", "codex", "cursor"],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: oldStars), forKey: LayoutPersistence.key)
        let store = LayoutStore(registry: .mock, defaults: defaults)
        XCTAssertFalse(store.isMetricPinned("claude.session"), "a menu-bar star from an older build is not a pin")

        XCTAssertTrue(store.setMetric("claude.weekly", pinned: true))

        let relaunched = LayoutStore(registry: .mock, defaults: defaults)
        XCTAssertTrue(relaunched.isMetricPinned("claude.weekly"))
        XCTAssertFalse(relaunched.isMetricPinned("codex.weekly"), "a pin belongs to one account")
        XCTAssertFalse(relaunched.isMetricPinned("claude.session"), "and to one metric")

        XCTAssertTrue(relaunched.setMetric("claude.weekly", pinned: false))
        XCTAssertFalse(LayoutStore(registry: .mock, defaults: defaults).isMetricPinned("claude.weekly"))
    }

    func testAHiddenMetricCannotBePinnedAndHidingUnpinsIt() {
        let defaults = isolatedDefaults()
        let store = LayoutStore(registry: .mock, defaults: defaults)
        XCTAssertTrue(store.setMetric("claude.weekly", pinned: true))

        XCTAssertTrue(store.setMetric("claude.weekly", shown: false))
        XCTAssertFalse(store.isMetricPinned("claude.weekly"))
        XCTAssertFalse(store.setMetric("claude.weekly", pinned: true))
        XCTAssertFalse(LayoutStore(registry: .mock, defaults: defaults).isMetricPinned("claude.weekly"))

        XCTAssertTrue(store.setMetric("claude.weekly", shown: true))
        XCTAssertFalse(store.isMetricPinned("claude.weekly"), "showing it again does not bring the pin back")
    }

    func testPinnedMetricsLeadPriorityInDashboardOrderAndAreListedOnlyThere() {
        let defaults = isolatedDefaults()
        let layout = LayoutStore(registry: .mock, defaults: defaults)
        let data = WidgetDataStore.forTesting([], registry: .mock, defaults: defaults)
        let lines: [String: [MetricLine]] = [
            "claude": [.percent("Session", 40), .percent("Weekly", 50)],
            "codex": [.percent("Session", 100), .percent("Weekly", 50)],
            "cursor": [.percent("Usage", 98)],
        ]
        for provider in MockData.providers {
            data.snapshots[provider.id] = ProviderSnapshot(provider: provider, plan: nil, lines: lines[provider.id] ?? [])
        }
        XCTAssertTrue(layout.reorderProvider(dragged: "codex", target: "claude"))
        XCTAssertTrue(layout.reorderMetric(dragged: "claude.weekly", target: "claude.session", in: "claude"))
        for id in ["claude.session", "claude.weekly", "codex.weekly"] {
            XCTAssertTrue(layout.setMetric(id, pinned: true))
        }

        let board = data.priorityBoard(in: layout.displayGroups, pinned: layout.state.priorityPinIDs, now: Date())

        XCTAssertEqual(board.pinned.map(\.id), ["codex.weekly", "claude.weekly", "claude.session"],
                       "the saved account order, then each account's metric order")
        XCTAssertEqual(board.attention.map(\.id), ["cursor.usage"])
        XCTAssertEqual(board.usedUp.map(\.id), ["codex.session"])

        XCTAssertTrue(layout.setMetric("cursor.usage", pinned: true))
        let allPinned = data.priorityBoard(in: layout.displayGroups, pinned: layout.state.priorityPinIDs, now: Date())
        XCTAssertEqual(allPinned.attention.map(\.id), ["cursor.usage"], "a pinned limit that is running out is listed under Running Out")
        XCTAssertEqual(allPinned.pinned.map(\.id), ["codex.weekly", "claude.weekly", "claude.session"], "and only there")
        XCTAssertFalse(allPinned.showsClearRow)
    }

    func testRemovingAnAccountRemovesItsPins() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let personal = accounts.add(kind: .claude, label: "Personal", credential: .apiKey("key"))
        let work = accounts.add(kind: .claude, label: "Work", credential: .apiKey("key"))
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], body: Data())
        })
        let layout = container.layout
        try await waitUntil { layout.provider(id: work.cardID) != nil }
        XCTAssertTrue(layout.setMetric("\(personal.cardID).session", pinned: true))
        XCTAssertTrue(layout.setMetric("\(work.cardID).session", pinned: true))

        accounts.remove(personal.id)
        try await waitUntil { layout.provider(id: personal.cardID) == nil }

        XCTAssertEqual(layout.state.priorityPinIDs, ["\(work.cardID).session"])
    }
}

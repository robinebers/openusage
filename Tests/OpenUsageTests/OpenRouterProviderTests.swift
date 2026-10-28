import XCTest
@testable import OpenUsage

@MainActor
final class OpenRouterProviderTests: XCTestCase {
    private static let cardLabels = ["Balance", "Today", "This Week", "This Month"]

    func testRefreshShowsBalanceAndPeriodSpendOnly() async throws {
        let http = RoutingHTTPClient { request in
            let body = request.url.absoluteString == OpenRouterUsageClient.creditsURL
                ? #"{"data":{"total_credits":100,"total_usage":22.23}}"#
                : #"{"data":{"usage_daily":1.5,"usage_weekly":4,"usage_monthly":12,"limit":1,"limit_remaining":0.25,"is_free_tier":false}}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let account = Account(kind: .openrouter, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("key"), for: account.id)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

        let snapshot = await runtime.refresh()

        XCTAssertEqual(snapshot.lines.map(\.label), Self.cardLabels)
        XCTAssertEqual(runtime.widgetDescriptors.map(\.metricLabel), Self.cardLabels)
        guard case .values(_, let values, _) = snapshot.lines.first
        else { return XCTFail("expected Balance value") }
        XCTAssertEqual(try XCTUnwrap(values.first?.number), 77.77, accuracy: 0.001)
    }

    func testFreshInstallPinsBalance() {
        let runtime = AccountProviderRuntime(account: Account(kind: .openrouter, label: "Work"), vault: InMemoryCredentialVault())
        let registry = WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors)

        let layout = LayoutStore(registry: registry, defaults: isolatedDefaults(), storageKey: "layout")

        XCTAssertEqual(layout.pinnedMetricIDs, ["\(runtime.provider.id).balance"])
    }

    func testRetiredCreditsAndKeyLimitInSavedLayoutAndCacheLeaveNoRow() {
        let runtime = AccountProviderRuntime(account: Account(kind: .openrouter, label: "Work"), vault: InMemoryCredentialVault())
        let card = runtime.provider.id
        let registry = WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors)
        let defaults = isolatedDefaults()
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.saveHidden(["\(card).credits", "\(card).keyLimit"])
        persistence.savePins(["\(card).credits", "\(card).keyLimit", "\(card).balance"])
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        cache.store(ProviderSnapshot(providerID: card, displayName: "OpenRouter", lines: [
            .progress(label: "Credits", used: 22.23, limit: 100, format: .dollars),
            .values(label: "Balance", values: [MetricValue(number: 77.77, kind: .dollars)]),
            .values(label: "Today", values: [MetricValue(number: 1.5, kind: .dollars)]),
            .values(label: "This Week", values: [MetricValue(number: 4, kind: .dollars)]),
            .values(label: "This Month", values: [MetricValue(number: 12, kind: .dollars)]),
            .progress(label: "Key Limit", used: 0.75, limit: 1, format: .dollars)
        ]))

        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        let data = WidgetDataStore.forTesting([runtime], registry: registry, cache: cache, defaults: defaults)

        XCTAssertEqual(layout.visibleDescriptors.map(\.id), ["balance", "today", "week", "month"].map { "\(card).\($0)" })
        XCTAssertEqual(layout.pinnedMetricIDs, ["\(card).balance"])
        for descriptor in layout.visibleDescriptors {
            XCTAssertTrue(data.data(for: descriptor).hasData, descriptor.id)
        }
    }

}

import XCTest
@testable import OpenUsage

@MainActor
final class WidgetDataStoreTests: XCTestCase {
    func testSoftWarningSurfacesOnHeaderWhilePartialDataStillLoads() async {
        // A *successful* snapshot carrying a `warning` (e.g. Claude's "Re-login for live usage" when the
        // login lacks user:profile) surfaces as the header's amber triangle via `warningMessage(for:)`,
        // while the partial data still loads and it is NOT treated as a hard refresh error.
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("claude"))
        let meter = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [meter],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)],
                warning: "Re-login for live usage. Run `claude` and sign in again."
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter]),
            providers: [runtime],
            defaults: makeUserDefaults("soft-warning")
        )

        await store.refreshAll()

        XCTAssertEqual(store.warningMessage(for: provider.id), "Re-login for live usage. Run `claude` and sign in again.")
        XCTAssertNil(store.errorMessage(for: provider.id))  // soft warning, not a hard error
        XCTAssertTrue(store.data(for: meter).hasData)       // partial data still loads
    }

    func testHardErrorTakesPrecedenceOverStaleSoftWarning() async {
        // Bugbot: after a failed refresh the store keeps the last good snapshot (with its `warning`) while
        // setting `providerErrors`. The header must show the current hard error, not the stale soft warning
        // from the prior success — so `headerNotice(for:)` is `errorMessage ?? warningMessage`.
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("claude"))
        let meter = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = TogglingProviderRuntime(
            provider: provider,
            descriptors: [meter],
            first: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)],
                warning: "Re-login for live usage."
            ),
            second: ProviderSnapshot.error(provider: provider, message: "Token expired. Run `claude` to log in again.")
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter]),
            providers: [runtime],
            defaults: makeUserDefaults("header-notice")
        )

        await store.refreshAll(force: true)  // success with warning
        XCTAssertEqual(store.warningMessage(for: provider.id), "Re-login for live usage.")
        XCTAssertEqual(store.headerNotice(for: provider.id), "Re-login for live usage.")

        await store.refreshAll(force: true)  // failure
        XCTAssertEqual(store.errorMessage(for: provider.id), "Token expired. Run `claude` to log in again.")
        XCTAssertEqual(store.warningMessage(for: provider.id), "Re-login for live usage.")  // stale, still present
        XCTAssertEqual(store.headerNotice(for: provider.id), "Token expired. Run `claude` to log in again.")  // error wins
    }

    func testUsesFreshCachedSnapshotInsteadOfRefreshingProvider() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(
            userDefaults: makeUserDefaults("fresh-cache"),
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-60)
        ))
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 80, limit: 100, format: .percent)],
                refreshedAt: now
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("fresh-cache-meter")
        )

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0)
        XCTAssertEqual(store.data(for: descriptor).valueText, "80%")
    }

    func testExpiredCacheRefreshesAndReplacesSnapshot() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = makeUserDefaults("expired-cache")
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-601)
        ))
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 80, limit: 100, format: .percent)],
                refreshedAt: now
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("expired-cache-meter")
        )

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.data(for: descriptor).valueText, "20%")
    }

    func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

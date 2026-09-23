import XCTest
@testable import OpenUsage

/// The last-known fallback as the dashboard sees it, through `WidgetDataStore.data(for:)`: it stands
/// in only while a provider can't answer, only for the account that measured it, and only within a
/// week of the measurement itself.
@MainActor
final class LastKnownMeterIntegrationTests: XCTestCase {
    private let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private lazy var session = WidgetDescriptor.percent(id: "claude.session", provider: provider, title: "Session")
    private lazy var extraUsage = WidgetDescriptor.boundedDollars(
        id: "claude.extraUsage", provider: provider, title: "Extra Usage", limit: 100
    )

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "LastKnownMeterIntegration.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func snapshot(_ lines: [MetricLine], refreshedAt: Date = Date()) -> ProviderSnapshot {
        ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: lines,
                         refreshedAt: refreshedAt)
    }

    private func sessionLine(_ used: Double) -> MetricLine {
        .progress(label: "Session", used: used, limit: 100, format: .percent)
    }

    /// What a rate-limited Claude card reports before any successful fetch: a status, no meters.
    private let rateLimited = MetricLine.badge(label: "Status", text: "Updates blocked by Anthropic")

    private func makeStore(
        defaults: UserDefaults,
        cache: ProviderSnapshotCache? = nil,
        snapshots: [ProviderSnapshot] = [],
        identityKeys: [String: String] = [:]
    ) -> WidgetDataStore {
        let descriptors = [session, extraUsage]
        let runtimes = snapshots.isEmpty ? [] : [
            SequenceProviderRuntime(provider: provider, descriptors: descriptors, snapshots: snapshots)
        ]
        return WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: descriptors),
            providers: runtimes,
            cache: cache ?? ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults,
            providerIdentityKeys: identityKeys
        )
    }

    func testARateLimitedProviderKeepsItsLastBars() async {
        let store = makeStore(defaults: makeDefaults("rateLimited"),
                              snapshots: [snapshot([sessionLine(42)]), snapshot([rateLimited])])
        await store.refreshAll(force: true)
        XCTAssertEqual(store.data(for: session).used, 42)

        await store.refreshAll(force: true)
        let data = store.data(for: session)

        XCTAssertTrue(data.hasData)
        XCTAssertTrue(data.isOutdated)
        XCTAssertEqual(data.used, 42)
    }

    func testAMetricASuccessfulResponseDropsStaysGone() async {
        // Regression: Claude omits Extra Usage when a successful response says it is turned off. The
        // response still has meters, so the provider answered, and the old allowance must not return.
        let defaults = makeDefaults("extraUsageOff")
        let store = makeStore(defaults: defaults, snapshots: [
            snapshot([sessionLine(42), .progress(label: "Extra Usage", used: 12, limit: 50, format: .dollars)]),
            snapshot([sessionLine(43)]),
        ])
        await store.refreshAll(force: true)
        XCTAssertEqual(store.data(for: extraUsage).used, 12)

        await store.refreshAll(force: true)

        XCTAssertFalse(store.data(for: extraUsage).hasData)
        XCTAssertFalse(store.data(for: session).isOutdated)

        // Relaunch into a rate limit: the session bar stands in, the removed allowance does not.
        let relaunched = makeStore(defaults: defaults, snapshots: [snapshot([rateLimited])])
        await relaunched.refreshAll(force: true)

        XCTAssertEqual(relaunched.data(for: session).used, 43)
        XCTAssertTrue(relaunched.data(for: session).isOutdated)
        XCTAssertFalse(relaunched.data(for: extraUsage).hasData)
    }

    func testAnotherAccountsReadingNeverPaintsAfterASwap() {
        // Regression: the launch guard dropped account A's snapshot for account B, and the fallback
        // then painted A's reading under B's card anyway.
        let defaults = makeDefaults("swap")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot([sessionLine(40)]), producedByIdentityKey: "acct-A")
        let accountA = makeStore(defaults: defaults, cache: cache, identityKeys: ["claude": "acct-A"])
        XCTAssertEqual(accountA.data(for: session).used, 40)

        let accountB = makeStore(defaults: defaults, cache: cache, identityKeys: ["claude": "acct-B"])

        XCTAssertNil(accountB.snapshots["claude"])
        XCTAssertFalse(accountB.data(for: session).hasData)
    }

    func testShowingAnAgedSnapshotNeverRenewsItsReading() async {
        // Regression: every render stamped the reading with the current time, so a snapshot older than
        // the cutoff came back to life for another week once the provider stopped answering.
        let defaults = makeDefaults("aged")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        let measured = Date().addingTimeInterval(-(LastKnownMeterStore.maximumAge + 3600))
        cache.store(snapshot([sessionLine(40)], refreshedAt: measured))
        let store = makeStore(defaults: defaults, cache: cache, snapshots: [snapshot([rateLimited])])
        XCTAssertEqual(store.data(for: session).used, 40, "The cached snapshot still paints at launch")

        await store.refreshAll(force: true)

        XCTAssertFalse(store.data(for: session).hasData)
    }

    func testResetAllSettingsIncludesTheMiniCardSettings() {
        // Regression: Reset All Settings left mini cards on and the style on Detailed.
        let defaults = makeDefaults("reset")
        defaults.set(true, forKey: MiniCardSetting.key)
        defaults.set(MiniCardStyle.detailed.rawValue, forKey: MiniCardStyle.key)

        AppContainer.removeResettableSettings(from: defaults)

        XCTAssertFalse(defaults.bool(forKey: MiniCardSetting.key, default: MiniCardSetting.fallback))
        XCTAssertEqual(defaults.enumValue(forKey: MiniCardStyle.key, default: MiniCardStyle.fallback), .singleRow)
    }
}

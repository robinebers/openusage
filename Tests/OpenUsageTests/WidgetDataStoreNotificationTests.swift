import XCTest
@testable import OpenUsage

/// End-to-end coverage of `WidgetDataStore.evaluateNotifications`: it resolves each enabled, visible
/// bounded metric, runs the pure milestone logic, gates on the per-trigger settings, dedups per metric
/// per window, and posts one notification per fired milestone. A recording sink stands in for
/// `AppNotifications`; pace worsens by raising the metric's `used` between refreshes (real-world
/// consumption), with `now` pinned so the projection stays deterministic.
@MainActor
final class WidgetDataStoreNotificationTests: XCTestCase {
    private let week: TimeInterval = 7 * 24 * 60 * 60
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    /// Reset window with ~90% of the week already elapsed at `base`, so `used%` ≈ the projected end %.
    private var resetsAt: Date { base.addingTimeInterval(week * 0.10) }

    /// A recording sink for posted notifications: each entry is `(idPrefix, title, subtitle, body)`.
    private final class Recorder {
        var posts: [(String, String, String, String)] = []
    }

    /// A mutable enablement flag the store reads through its injected closure (so a test can flip it
    /// without a "mutated after capture" warning on a captured local var).
    private final class EnabledFlag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    /// A provider whose snapshot can be swapped between refreshes to simulate rising usage.
    private final class MutableRuntime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        var snapshot: ProviderSnapshot
        init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
            self.provider = provider
            self.widgetDescriptors = descriptors
            self.snapshot = snapshot
        }
        func refresh() async -> ProviderSnapshot { snapshot }
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suite = "WidgetDataStoreNotificationTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("cursor"))

    private static func descriptor() -> WidgetDescriptor {
        WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 10, limit: 100)
        )
    }

    private func snapshot(used: Double, resetsAt: Date? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: Self.provider.id,
            displayName: Self.provider.displayName,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent,
                              resetsAt: resetsAt ?? self.resetsAt, periodDurationMs: Int(week * 1000))]
        )
    }

    private func makeStore(
        used: Double,
        settings: NotificationSettingsStore,
        recorder: Recorder,
        defaultsName: String,
        isEnabled: @escaping @MainActor (String) -> Bool = { _ in true },
        delivered: @escaping @MainActor () -> Bool = { true }
    ) -> (WidgetDataStore, MutableRuntime, WidgetDescriptor) {
        let descriptor = Self.descriptor()
        let runtime = MutableRuntime(provider: Self.provider, descriptors: [descriptor], snapshot: snapshot(used: used))
        let defaults = makeUserDefaults(defaultsName)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [Self.provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults,
            isProviderEnabled: isEnabled,
            orderedDescriptors: { [descriptor] },
            notificationSettings: { settings },
            postNotification: { idPrefix, title, subtitle, body in
                recorder.posts.append((idPrefix, title, subtitle, body))
                return delivered()
            }
        )
        return (store, runtime, descriptor)
    }

    /// All three triggers on — the state the default-on build used to give for free; tests opt in
    /// explicitly now that the store defaults to off.
    private func allOn(_ settings: NotificationSettingsStore) {
        settings.underTenPercent = true
        settings.healthyToClose = true
        settings.closeToRunningOut = true
    }

    func testHealthyToCloseFiresOnceThroughTheStore() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("h2c-settings"))
        allOn(settings)
        let recorder = Recorder()
        // 80% used at ~90% elapsed → projected ~89% → healthy.
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "h2c")
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.isEmpty, "healthy should not fire")

        // Usage rises to 87% → projected ~96.7% → close.
        runtime.snapshot = snapshot(used: 87)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.count, 1)
        XCTAssertEqual(recorder.posts.first?.0, "test.healthyToClose")
        XCTAssertEqual(recorder.posts.first?.1, "Cutting It Close")

        // Staying yellow doesn't re-fire.
        await store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.count, 1)
    }

    func testCloseToRunningOutFiresThroughTheStore() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("c2r-settings"))
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 87, settings: settings, recorder: recorder, defaultsName: "c2r")
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)   // close → primes (first real obs), no fire
        XCTAssertTrue(recorder.posts.isEmpty, "first launch primes the baseline without firing")

        // Usage rises to 95% → projected ~105% → red.
        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.contains { $0.0 == "test.closeToRunningOut" })
        XCTAssertTrue(recorder.posts.contains { $0.3 == "Projected to finish before the limit resets." })
        XCTAssertTrue(recorder.posts.contains { $0.2 == "Test Session" })
    }

    func testResetJitterDoesNotRefireRunningOutThroughTheStore() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("jitter-settings"))
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "jitter")
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)   // healthy -> primes, no fire

        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)   // -> red, fires once
        XCTAssertEqual(recorder.posts.filter { $0.0 == "test.closeToRunningOut" }.count, 1)

        runtime.snapshot = snapshot(used: 95, resetsAt: resetsAt.addingTimeInterval(0.09))
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)   // same red state, reset jitter only

        XCTAssertEqual(recorder.posts.filter { $0.0 == "test.closeToRunningOut" }.count, 1)
    }

    func testAllTogglesOffSuppressesAllPosts() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("all-off-settings"))
        settings.underTenPercent = false
        settings.healthyToClose = false
        settings.closeToRunningOut = false
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "all-off")
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.isEmpty)
    }

    func testPerTriggerOffSuppressesThatMilestoneOnly() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("per-trigger-settings"))
        allOn(settings)
        settings.healthyToClose = false   // turn off "Cutting It Close" only
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "per-trigger")
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        runtime.snapshot = snapshot(used: 87)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertFalse(recorder.posts.contains { $0.0 == "test.healthyToClose" })
        // The critical trigger is still on: pushing to red fires it.
        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.contains { $0.0 == "test.closeToRunningOut" })
    }

    func testDisablingProviderDropsItsNotificationState() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("disable-settings"))
        allOn(settings)
        let recorder = Recorder()
        let enabled = EnabledFlag(true)
        // Prime from healthy, then worsen to red so a milestone fires before the disable.
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder,
                                            defaultsName: "disable", isEnabled: { _ in enabled.value })
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)   // healthy → primes, no fire
        XCTAssertEqual(recorder.posts.count, 0)
        runtime.snapshot = snapshot(used: 95)    // → red, fires
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        let firstCount = recorder.posts.count
        XCTAssertGreaterThan(firstCount, 0)

        // Disable the provider: evaluation skips it (and prunes its state), so nothing new fires.
        enabled.value = false
        await store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.count, firstCount)
    }

    func testLowRemainingFiresInUsedDisplayMode() async {
        // Regression: the under-10%-remaining check must use remaining share, not the display-mode-
        // dependent `fraction`. When the meter shows "used", `data.fraction` is `used/limit` (0.95
        // here), so the old `< 0.10` check would NOT fire "Almost Out" despite only 5% remaining.
        // `remainingFraction` fires it regardless of the used/remaining display choice. Prime from
        // healthy first so the under-10% edge is a real transition, not a cold start.
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("used-mode-settings"))
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "used-mode")
        store.meterStyle = .used
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)   // healthy → primes, no fire
        runtime.snapshot = snapshot(used: 95)    // → under 10% remaining
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertTrue(
            recorder.posts.contains { $0.0 == "test.underTenPercent" },
            "Almost Out must fire on <10% remaining even when the meter displays 'used'"
        )
    }

    func testFailedDeliveryRetriesNextTick() async {
        // Regression: if delivery fails (not authorized, or scheduling errored), the milestone must not
        // be marked fired — the edge stays un-consumed so it re-fires on the next evaluation instead of
        // being lost for the rest of the reset window.
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("retry-settings"))
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder,
                                            defaultsName: "retry", delivered: { false })
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)   // healthy → primes, no fire
        runtime.snapshot = snapshot(used: 87)          // → close
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)   // attempt 1 (delivery "fails")
        // Still close on the next tick — the un-delivered milestone re-fires instead of being deduped.
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)   // attempt 2 (re-tried)
        XCTAssertEqual(recorder.posts.count, 2, "failed delivery should retry on the next tick")
    }
}

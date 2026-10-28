import XCTest
@testable import OpenUsage

/// End-to-end coverage of the loop's notification step (`QuotaNotificationEvaluator.evaluate` over the
/// store's values, as `AppContainer` runs it): it resolves each visible
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

    private static let provider = Provider(id: "test", displayName: "Test", icon: "cursor")

    /// The loop's notification step over the store the test built.
    private var notify: @MainActor (Date) async -> Void = { _ in }

    private func notifier(
        _ store: WidgetDataStore,
        descriptors: [WidgetDescriptor],
        providers: [Provider],
        settings: NotificationSettingsStore,
        recorder: Recorder,
        delivered: @escaping @MainActor () -> Bool = { true }
    ) -> @MainActor (Date) async -> Void {
        let evaluator = QuotaNotificationEvaluator { idPrefix, title, subtitle, body in
            recorder.posts.append((idPrefix, title, subtitle, body))
            return delivered()
        }
        return { now in
            await evaluator.evaluate(
                descriptors,
                data: store.data(for:),
                toggles: settings.toggles,
                now: now,
                providerName: { id in providers.first { $0.id == id }?.fullName ?? id }
            )
        }
    }

    private static func descriptor() -> WidgetDescriptor {
        WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", kind: .percent, used: 10, limit: 100)
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
        delivered: @escaping @MainActor () -> Bool = { true }
    ) -> (WidgetDataStore, StubRuntime, WidgetDescriptor) {
        let descriptor = Self.descriptor()
        let runtime = StubRuntime(provider: Self.provider, descriptors: [descriptor], snapshot: snapshot(used: used))
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([runtime], defaults: defaults)
        notify = notifier(
            store, descriptors: [descriptor], providers: [Self.provider], settings: settings, recorder: recorder,
            delivered: delivered
        )
        return (store, runtime, descriptor)
    }

    /// All three triggers on; the store defaults to off, so tests opt in explicitly.
    private func allOn(_ settings: NotificationSettingsStore) {
        settings.underTenPercent = true
        settings.healthyToClose = true
        settings.closeToRunningOut = true
    }

    private func evaluate(
        _ store: WidgetDataStore,
        runtime: StubRuntime,
        used: Double? = nil,
        resetsAt: Date? = nil
    ) async {
        if let used {
            let next = snapshot(used: used, resetsAt: resetsAt)
            runtime.answer = { _ in next }
        }
        await store.refreshAll(force: true)
        await notify(base)
    }

    /// Two accounts of one provider name themselves in the subtitle ("Claude · Personal Session",
    /// "Claude · Work Session"), never "Claude Session" twice.
    func testTwoAccountsOfOneProviderNameThemselvesInTheSubtitle() async {
        let settings = NotificationSettingsStore(defaults: isolatedDefaults())
        allOn(settings)
        let recorder = Recorder()
        let providers = [("claude@aaaa", "Personal"), ("claude@bbbb", "Work")].map {
            Provider(id: $0.0, displayName: "Claude", icon: "claude", accountLabel: $0.1)
        }
        let descriptors = providers.map { provider in
            WidgetDescriptor(
                id: "\(provider.id).session",
                providerID: provider.id,
                metricLabel: "Session",
                sample: WidgetData(title: "Session", kind: .percent, used: 10, limit: 100)
            )
        }
        func snapshot(_ provider: Provider, used: Double) -> ProviderSnapshot {
            ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: used, limit: 100, format: .percent,
                                  resetsAt: resetsAt, periodDurationMs: Int(week * 1000))]
            )
        }
        let runtimes = zip(providers, descriptors).map {
            StubRuntime(provider: $0, descriptors: [$1], snapshot: snapshot($0, used: 80))
        }
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting(runtimes, defaults: defaults)
        notify = notifier(store, descriptors: descriptors, providers: providers, settings: settings, recorder: recorder)
        await store.refreshAll(force: true)
        await notify(base)
        XCTAssertTrue(recorder.posts.isEmpty, "healthy should not fire")

        for (runtime, provider) in zip(runtimes, providers) {
            let next = snapshot(provider, used: 87)
            runtime.answer = { _ in next }
        }
        await store.refreshAll(force: true)
        await notify(base)

        XCTAssertEqual(recorder.posts.map(\.2), ["Claude · Personal Session", "Claude · Work Session"])
    }

    func testHealthyToCloseFiresOnceThroughTheStore() async {
        let settings = NotificationSettingsStore(defaults: isolatedDefaults())
        allOn(settings)
        let recorder = Recorder()
        // 80% used at ~90% elapsed → projected ~89% → healthy.
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder)
        await evaluate(store, runtime: runtime)
        XCTAssertTrue(recorder.posts.isEmpty, "healthy should not fire")

        // Usage rises to 87% → projected ~96.7% → close.
        await evaluate(store, runtime: runtime, used: 87)
        XCTAssertEqual(recorder.posts.count, 1)
        XCTAssertEqual(recorder.posts.first?.0, "test.healthyToClose")
        XCTAssertEqual(recorder.posts.first?.1, "Cutting It Close")

        // Staying orange doesn't re-fire.
        await notify(base)
        XCTAssertEqual(recorder.posts.count, 1)
    }

    func testCloseToRunningOutFiresThroughTheStore() async {
        let settings = NotificationSettingsStore(defaults: isolatedDefaults())
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 87, settings: settings, recorder: recorder)
        await evaluate(store, runtime: runtime)
        XCTAssertTrue(recorder.posts.isEmpty, "first launch primes the baseline without firing")

        // Usage rises to 95% → projected ~105% → red.
        await evaluate(store, runtime: runtime, used: 95)
        XCTAssertTrue(recorder.posts.contains { $0.0 == "test.closeToRunningOut" })
        XCTAssertTrue(recorder.posts.contains { $0.3 == "Projected to finish before the limit resets." })
        XCTAssertTrue(recorder.posts.contains { $0.2 == "Test Session" })
    }

    func testResetJitterDoesNotRefireRunningOutThroughTheStore() async {
        let settings = NotificationSettingsStore(defaults: isolatedDefaults())
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder)
        await evaluate(store, runtime: runtime)

        await evaluate(store, runtime: runtime, used: 95)
        XCTAssertEqual(recorder.posts.filter { $0.0 == "test.closeToRunningOut" }.count, 1)

        await evaluate(store, runtime: runtime, used: 95, resetsAt: resetsAt.addingTimeInterval(0.09))

        XCTAssertEqual(recorder.posts.filter { $0.0 == "test.closeToRunningOut" }.count, 1)
    }

    func testAllTogglesOffSuppressesAllPosts() async {
        let settings = NotificationSettingsStore(defaults: isolatedDefaults())
        settings.underTenPercent = false
        settings.healthyToClose = false
        settings.closeToRunningOut = false
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder)
        await evaluate(store, runtime: runtime)
        await evaluate(store, runtime: runtime, used: 95)
        XCTAssertTrue(recorder.posts.isEmpty)
    }

    func testPerTriggerOffSuppressesThatMilestoneOnly() async {
        let settings = NotificationSettingsStore(defaults: isolatedDefaults())
        allOn(settings)
        settings.healthyToClose = false   // turn off "Cutting It Close" only
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder)
        await evaluate(store, runtime: runtime)
        await evaluate(store, runtime: runtime, used: 87)
        XCTAssertFalse(recorder.posts.contains { $0.0 == "test.healthyToClose" })
        // The critical trigger is still on: pushing to red fires it.
        await evaluate(store, runtime: runtime, used: 95)
        XCTAssertTrue(recorder.posts.contains { $0.0 == "test.closeToRunningOut" })
    }

    func testLowRemainingFiresInUsedDisplayMode() async {
        // The under-10%-remaining check must use remaining share, not the display-mode-
        // dependent `fraction`. When the meter shows "used", `data.fraction` is `used/limit` (0.95
        // here), so a `< 0.10` check on it would not fire "Almost Out" despite only 5% remaining.
        // `remainingFraction` fires it regardless of the used/remaining display choice. Prime from
        // healthy first so the under-10% edge is a real transition, not a cold start.
        let settings = NotificationSettingsStore(defaults: isolatedDefaults())
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder)
        store.meterStyle = .used
        await evaluate(store, runtime: runtime)
        await evaluate(store, runtime: runtime, used: 95)
        XCTAssertTrue(
            recorder.posts.contains { $0.0 == "test.underTenPercent" },
            "Almost Out must fire on <10% remaining even when the meter displays 'used'"
        )
    }

    func testFailedDeliveryRetriesNextTick() async {
        // If delivery fails (not authorized, or scheduling errored), the milestone must not
        // be marked fired — the edge stays un-consumed so it re-fires on the next evaluation instead of
        // being lost for the rest of the reset window.
        let settings = NotificationSettingsStore(defaults: isolatedDefaults())
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder,
                                            delivered: { false })
        await evaluate(store, runtime: runtime)
        await evaluate(store, runtime: runtime, used: 87)
        await evaluate(store, runtime: runtime)
        XCTAssertEqual(recorder.posts.count, 2, "failed delivery should retry on the next tick")
    }
}

import XCTest
@testable import OpenUsage

@MainActor
final class WidgetDataStoreNotificationTests: XCTestCase {
    private let week: TimeInterval = 7 * 24 * 60 * 60
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var resetsAt: Date { base.addingTimeInterval(week * 0.10) }

    private final class Recorder {
        var posts: [(String, String, String, String)] = []
    }

    private static let provider = Provider(id: "test", kind: .cursor)

    private var notify: @MainActor (Date) async -> Void = { _ in }

    private func notifier(
        _ store: WidgetDataStore,
        descriptors: [WidgetDescriptor],
        providers: [Provider],
        settings: UserDefaults,
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
                isOn: { settings.bool(forKey: $0.settingKey) },
                now: now,
                providerName: { id in providers.first { $0.id == id }?.fullName ?? id }
            )
        }
    }

    private static func descriptor() -> WidgetDescriptor {
        WidgetDescriptor(
            provider: provider,
            key: "session",
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
        settings: UserDefaults,
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

    private func allOn(_ settings: UserDefaults) {
        for milestone in PaceMilestone.allCases { settings.set(true, forKey: milestone.settingKey) }
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

    func testTwoAccountsOfOneProviderNameThemselvesInTheSubtitle() async {
        let settings = isolatedDefaults()
        allOn(settings)
        let recorder = Recorder()
        let providers = [("claude@aaaa", "Personal"), ("claude@bbbb", "Work")].map {
            Provider(id: $0.0, kind: .claude, accountLabel: $0.1)
        }
        let descriptors = providers.map { provider in
            WidgetDescriptor(
                provider: provider,
                key: "session",
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
        let settings = isolatedDefaults()
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder)
        await evaluate(store, runtime: runtime)
        XCTAssertTrue(recorder.posts.isEmpty, "healthy should not fire")

        await evaluate(store, runtime: runtime, used: 87)
        XCTAssertEqual(recorder.posts.count, 1)
        XCTAssertEqual(recorder.posts.first?.0, "test.healthyToClose")
        XCTAssertEqual(recorder.posts.first?.1, "Cutting It Close")

        await notify(base)
        XCTAssertEqual(recorder.posts.count, 1)
    }

    func testCloseToRunningOutFiresThroughTheStore() async {
        let settings = isolatedDefaults()
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 87, settings: settings, recorder: recorder)
        await evaluate(store, runtime: runtime)
        XCTAssertTrue(recorder.posts.isEmpty, "first launch primes the baseline without firing")

        await evaluate(store, runtime: runtime, used: 95)
        XCTAssertTrue(recorder.posts.contains { $0.0 == "test.closeToRunningOut" })
        XCTAssertTrue(recorder.posts.contains { $0.3 == "Projected to finish before the limit resets." })
        XCTAssertTrue(recorder.posts.contains { $0.2 == "Cursor Session" })
    }

    func testResetJitterDoesNotRefireRunningOutThroughTheStore() async {
        let settings = isolatedDefaults()
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
        let settings = isolatedDefaults()
        settings.set(false, forKey: PaceMilestone.underTenPercent.settingKey)
        settings.set(false, forKey: PaceMilestone.healthyToClose.settingKey)
        settings.set(false, forKey: PaceMilestone.closeToRunningOut.settingKey)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder)
        await evaluate(store, runtime: runtime)
        await evaluate(store, runtime: runtime, used: 95)
        XCTAssertTrue(recorder.posts.isEmpty)
    }

    func testAnOffTriggerDoesNotConsumeTheEdge() async {
        let settings = isolatedDefaults()
        settings.set(true, forKey: PaceMilestone.closeToRunningOut.settingKey)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder)
        await evaluate(store, runtime: runtime)
        await evaluate(store, runtime: runtime, used: 87)
        XCTAssertTrue(recorder.posts.isEmpty)

        settings.set(true, forKey: PaceMilestone.healthyToClose.settingKey)
        await notify(base)
        XCTAssertEqual(recorder.posts.map(\.0), ["test.healthyToClose"])
    }

    func testPerTriggerOffSuppressesThatMilestoneOnly() async {
        let settings = isolatedDefaults()
        allOn(settings)
        settings.set(false, forKey: PaceMilestone.healthyToClose.settingKey)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder)
        await evaluate(store, runtime: runtime)
        await evaluate(store, runtime: runtime, used: 87)
        XCTAssertFalse(recorder.posts.contains { $0.0 == "test.healthyToClose" })
        await evaluate(store, runtime: runtime, used: 95)
        XCTAssertTrue(recorder.posts.contains { $0.0 == "test.closeToRunningOut" })
    }

    func testLowRemainingFiresInUsedDisplayMode() async {
        let settings = isolatedDefaults()
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
        let settings = isolatedDefaults()
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

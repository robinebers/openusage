import XCTest
@testable import OpenUsage

@MainActor
final class PriorityLimitsTests: XCTestCase {
    func testMovingOneLevelOntoOrPastTheOtherPushesTheOtherAStep() {
        var limits = PriorityLimits.standard
        limits.critical = 25
        limits.warning = 20
        XCTAssertEqual([limits.warning, limits.critical], [20, 15], "Warning at or under Critical drops Critical to Warning - 5")
        limits.critical = 25
        XCTAssertEqual([limits.warning, limits.critical], [30, 25], "Critical at or over Warning raises Warning to Critical + 5")

        let badSave = PriorityLimits(warning: 20, critical: 25)
        XCTAssertEqual([badSave.warning, badSave.critical], [20, 15])
        let outOfRange = PriorityLimits(warning: 90, critical: 2)
        XCTAssertEqual([outOfRange.warning, outOfRange.critical], [70, 5])
    }

    func testRaisingWarningTo45TurnsALimitWith40PercentLeftOrangeAndListsItUnderRunningOut() async {
        let provider = Provider(id: "test", kind: .cursor)
        let descriptor = WidgetDescriptor(
            provider: provider, key: "weekly", metricLabel: "Weekly",
            sample: WidgetData(title: "Weekly", kind: .percent, used: 0, limit: 100)
        )
        let snapshot = ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName,
            lines: [.progress(label: "Weekly", used: 60, limit: 100, format: .percent, resetsAt: nil, periodDurationMs: nil)]
        )
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting(
            [StubRuntime(provider: provider, descriptors: [descriptor], snapshot: snapshot)], defaults: defaults
        )
        await store.refreshAll(force: true)
        let groups = [ProviderMetrics(provider: provider, metrics: [descriptor])]
        func runningOut() -> [String] {
            PriorityBoard.make(accounts: store.accounts(in: groups), now: Date()).attention.map(\.id)
        }
        XCTAssertEqual(store.data(for: descriptor).severity, .normal)
        XCTAssertEqual(runningOut(), [])

        store.priorityLimits.warning = 45

        XCTAssertEqual(store.data(for: descriptor).severity, .warning)
        XCTAssertEqual(runningOut(), [descriptor.id])
        XCTAssertEqual(WidgetDataStore.forTesting([], defaults: defaults).priorityLimits.warning, 45, "the choice is saved")
    }
}

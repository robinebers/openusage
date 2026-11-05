import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PaceMarkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 24 * 3600
    private let personal = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")

    private func limit(used: Double, elapsed: Double = 0.25, period: TimeInterval? = nil, kind: MetricKind = .percent,
                       displayMode: WidgetDisplayMode = .remaining) -> WidgetData {
        let period = period ?? week
        var data = WidgetData(title: "Weekly", kind: kind, used: used, limit: 100, displayMode: displayMode)
        data.resetsAt = now.addingTimeInterval(period * (1 - elapsed))
        data.periodDurationMs = Int(period * 1000)
        return data
    }

    func testTheMarkSitsAtTheElapsedShareUnderUsedAndAtWhatWouldBeLeftUnderLeft() throws {
        let used = try XCTUnwrap(limit(used: 60, displayMode: .used).dashboardRow(now: now).paceMark)
        XCTAssertEqual(used, 0.25, accuracy: 1e-9)
        let left = try XCTUnwrap(limit(used: 60, displayMode: .remaining).dashboardRow(now: now).paceMark)
        XCTAssertEqual(left, 0.75, accuracy: 1e-9)
    }

    /// As in 0.7, the tick is drawn at about half the strength of the text, in light and in dark.
    func testTheMarkIsDrawnAtAboutHalfStrength() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let mark = Theme.paceMark.resolve(in: environment)
            let text = Color.primary.resolve(in: environment)
            XCTAssertEqual(Double(mark.opacity / text.opacity), 0.55, accuracy: 0.01, "\(scheme)")
            XCTAssertEqual([mark.red, mark.green, mark.blue], [text.red, text.green, text.blue], "\(scheme)")
        }
    }

    func testTheMarkMovesWithTheClock() throws {
        let data = limit(used: 10, elapsed: 0.25, displayMode: .used)
        let later = try XCTUnwrap(data.paceMark(now: now.addingTimeInterval(week / 4)))
        XCTAssertEqual(later, 0.5, accuracy: 1e-9)
    }

    func testEveryLimitWithAWindowGetsAMarkEvenUnusedOnPaceOrInDollars() {
        XCTAssertNotNil(limit(used: 0).paceMark(now: now), "0% used still shows it's under pace")
        XCTAssertNotNil(limit(used: 25, displayMode: .used).paceMark(now: now), "exactly on pace")
        XCTAssertNotNil(limit(used: 90).paceMark(now: now), "over pace")
        XCTAssertNotNil(limit(used: 40, kind: .dollars).paceMark(now: now), "a dollar limit with a window, like Cursor Extra Usage")
    }

    func testNoMarkWithoutAWindowThatHasStartedAndNotReset() {
        XCTAssertNil(limit(used: 10, elapsed: 0.009).paceMark(now: now), "under 1% of a week has passed")
        XCTAssertNotNil(limit(used: 10, elapsed: 0.011).paceMark(now: now))
        XCTAssertNil(limit(used: 10, elapsed: 50.0 / 3600, period: 3600).paceMark(now: now), "under a minute has passed")
        XCTAssertNotNil(limit(used: 10, elapsed: 70.0 / 3600, period: 3600).paceMark(now: now))
        XCTAssertNil(limit(used: 10, elapsed: 1).paceMark(now: now), "at the reset")
        XCTAssertNil(limit(used: 10, elapsed: 1.1).paceMark(now: now), "after the reset")

        var noPeriod = limit(used: 10)
        noPeriod.periodDurationMs = nil
        XCTAssertNil(noPeriod.paceMark(now: now), "a limit with no window length, like OpenRouter's Key Limit")
        var noReset = limit(used: 10)
        noReset.resetsAt = nil
        XCTAssertNil(noReset.paceMark(now: now))

        var fresh = limit(used: 0)
        fresh.sessionStartSignal = .zeroUsage
        XCTAssertNil(fresh.paceMark(now: now), "a session that hasn't started")
    }

    func testNoMarkOnFiguresBalancesOrUsedUpLimits() {
        var balance = WidgetData(title: "Credits", kind: .dollars, used: 12.4, limit: nil)
        balance.resetsAt = now.addingTimeInterval(week / 2)
        balance.periodDurationMs = Int(week * 1000)
        XCTAssertNil(balance.paceMark(now: now))
        XCTAssertNil(balance.dashboardRow(now: now).paceMark)

        var noData = limit(used: 10)
        noData.hasData = false
        XCTAssertNil(noData.paceMark(now: now))

        XCTAssertNil(limit(used: 100).paceMark(now: now), "used up")
        XCTAssertNil(limit(used: 99.996).paceMark(now: now), "used up at the shown precision")
        XCTAssertNil(limit(used: 100, displayMode: .used).dashboardRow(now: now).paceMark)
    }

    func testTheSwitchDefaultsToOffTurnsMarksOnAndOffOnBothTabsAndSurvivesARelaunch() {
        let descriptor = WidgetDescriptor.percent(key: "weekly", provider: personal, title: "Weekly")
        let group = ProviderMetrics(provider: personal, metrics: [descriptor])
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting(
            [], registry: WidgetRegistry(providers: [personal], descriptors: [descriptor]), defaults: defaults, now: { self.now }
        )
        store.snapshots[personal.id] = ProviderSnapshot(
            provider: personal, plan: nil,
            lines: [.percent("Weekly", 95, resetsAt: now.addingTimeInterval(week / 2), periodMs: MetricPeriod.weekMs)],
            refreshedAt: now
        )
        func allUsageMarks() -> [Double?] { store.accounts(in: [group]).flatMap(\.lines).map { $0.data.dashboardRow(now: now).paceMark } }
        func priorityMarks() -> [Double?] { store.priorityBoard(in: [group], now: now).attention.map { $0.data.paceMark(now: now) } }

        XCTAssertFalse(store.showsPaceMarks)
        XCTAssertEqual(allUsageMarks(), [nil])
        XCTAssertEqual(priorityMarks(), [nil], "the limit is listed under Running Out without a mark")

        store.showsPaceMarks = true
        XCTAssertEqual(allUsageMarks(), [0.5])
        XCTAssertEqual(priorityMarks(), [0.5])
        XCTAssertTrue(WidgetDataStore.forTesting([], defaults: defaults).showsPaceMarks, "the switch survives a relaunch")

        store.showsPaceMarks = false
        XCTAssertEqual(allUsageMarks(), [nil])
        XCTAssertEqual(priorityMarks(), [nil])
    }
}

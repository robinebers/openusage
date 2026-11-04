import XCTest
@testable import OpenUsage

@MainActor
final class UseItOrLoseItPriorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600

    private let personal = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let chatGPT = Provider(id: "codex@1", kind: .codex, accountLabel: "ChatGPT")

    private func limit(
        _ title: String, used: Double, resetsIn: TimeInterval, periodMs: Int = MetricPeriod.weekMs, kind: MetricKind = .percent
    ) -> WidgetData {
        var data = WidgetData(title: title, kind: kind, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(resetsIn)
        data.periodDurationMs = periodMs
        return data
    }

    private func account(_ provider: Provider, _ lines: WidgetData...) -> DashboardAccount {
        DashboardAccount(provider: provider, lines: lines.map { data in
            DashboardLine(
                descriptor: WidgetDescriptor(provider: provider, key: data.title, metricLabel: data.title, sample: data),
                data: data
            )
        })
    }

    private func ids(_ items: [PriorityItem]) -> [String] { items.map(\.id) }

    func testListsLimitsAboutToResetUnusedInTheirOwnSectionSoonestResetFirstAndOnlyWithTheSwitchOn() {
        let accounts = [
            account(personal,
                    limit("Weekly", used: 30, resetsIn: 18 * hour),
                    limit("Session", used: 10, resetsIn: 2 * hour, periodMs: MetricPeriod.sessionMs),
                    limit("Daily", used: 10, resetsIn: 3 * hour, periodMs: MetricPeriod.dayMs),
                    limit("Half", used: 50, resetsIn: 4 * hour),
                    limit("Later", used: 10, resetsIn: 25 * hour)),
            account(chatGPT,
                    limit("Weekly", used: 20, resetsIn: 6 * hour),
                    limit("Key Limit", used: 10, resetsIn: 5 * hour, periodMs: MetricPeriod.monthMs, kind: .dollars)),
        ]

        let board = PriorityBoard.make(accounts: accounts, burningFast: BurningFast(), useItOrLoseIt: true, now: now)

        XCTAssertEqual(ids(board.useItOrLoseIt), ["codex@1.Weekly", "claude@1.Weekly"],
                       "soonest reset first; sessions, daily windows, exactly half left, over a day out, and dollar caps stay off")
        XCTAssertEqual(board.useItOrLoseIt.map { $0.resetsInText(now: now) }, ["Resets in 6h", "Resets in 18h"])
        XCTAssertEqual(board.useItOrLoseIt.map(\.reason.severity), [.normal, .normal], "the ring keeps meaning what's left")
        XCTAssertTrue(board.attention.isEmpty, "nothing here is running out")
        XCTAssertTrue(board.showsClearRow, "Running Out still says All Clear")
        XCTAssertEqual(board.summary, .listed)
        XCTAssertTrue(MenuBarContentBuilder.build(board: board, limit: .upToFive).isEmpty, "the menu bar is for running out")

        let off = PriorityBoard.make(accounts: accounts, burningFast: BurningFast(), useItOrLoseIt: false, now: now)
        XCTAssertTrue(off.useItOrLoseIt.isEmpty)
        XCTAssertEqual(off.summary, .allClear)
    }

    func testListsExactlyWhatTheAlertWouldFireFor() {
        for periodMs in [MetricPeriod.sessionMs, MetricPeriod.dayMs, MetricPeriod.weekMs, MetricPeriod.monthMs] {
            for kind in [MetricKind.percent, .dollars] {
                for used in [0.0, 30, 49, 49.6, 50, 51] {
                    for resetsIn in [-hour, 1, hour, 24 * hour, 24 * hour + 1] {
                        let data = limit("Weekly", used: used, resetsIn: resetsIn, periodMs: periodMs, kind: kind)
                        let board = PriorityBoard.make(accounts: [account(personal, data)], useItOrLoseIt: true, now: now)
                        XCTAssertEqual(!board.useItOrLoseIt.isEmpty, PaceNotificationLogic.isUnusedNearReset(data, now: now),
                                       "\(kind) \(periodMs)ms window, \(used) used, resets in \(resetsIn)s")
                    }
                }
            }
        }
    }

    func testAPinnedLimitAboutToResetUnusedMovesOutOfPinned() {
        let accounts = [account(personal, limit("Weekly", used: 30, resetsIn: 18 * hour))]
        let board = PriorityBoard.make(accounts: accounts, pinned: ["claude@1.Weekly"], useItOrLoseIt: true, now: now)
        XCTAssertEqual(ids(board.useItOrLoseIt), ["claude@1.Weekly"])
        XCTAssertEqual(board.useItOrLoseIt.map(\.isPinned), [true])
        XCTAssertTrue(board.pinned.isEmpty)
        XCTAssertTrue(board.showsClearRow)
    }

    func testTheStoreSwitchDefaultsToOnAndSurvivesARelaunch() {
        let descriptor = WidgetDescriptor.percent(key: "weekly", provider: personal, title: "Weekly")
        let group = ProviderMetrics(provider: personal, metrics: [descriptor])
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting(
            [], registry: WidgetRegistry(providers: [personal], descriptors: [descriptor]), defaults: defaults, now: { self.now }
        )
        store.snapshots[personal.id] = ProviderSnapshot(
            provider: personal, plan: nil,
            lines: [.percent("Weekly", 30, resetsAt: now.addingTimeInterval(18 * hour), periodMs: MetricPeriod.weekMs)],
            refreshedAt: now
        )
        func listed() -> [String] { ids(store.priorityBoard(in: [group], now: now).useItOrLoseIt) }

        XCTAssertTrue(store.showsUseItOrLoseIt)
        XCTAssertEqual(listed(), [descriptor.id])
        store.showsUseItOrLoseIt = false
        XCTAssertTrue(listed().isEmpty)
        XCTAssertFalse(WidgetDataStore.forTesting([], defaults: defaults).showsUseItOrLoseIt, "the switch survives a relaunch")
    }
}

import XCTest
@testable import OpenUsage

@MainActor
final class BurningFastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 24 * 3600
    private var week: TimeInterval { 7 * day }
    private var session: TimeInterval { 5 * hour }

    private let personal = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let chatGPT = Provider(id: "codex@1", kind: .codex, accountLabel: "ChatGPT")

    /// A limit `elapsed` into its window, which is a week unless said otherwise.
    private func paced(_ title: String, used: Double, elapsed: Double, period: TimeInterval? = nil) -> WidgetData {
        let period = period ?? week
        var data = WidgetData(title: title, kind: .percent, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval((1 - elapsed) * period)
        data.periodDurationMs = Int(period * 1000)
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

    func testALimitBurningFastJoinsRunningOutWithPlentyLeftRankedByWhenItRunsOut() {
        let accounts = [
            account(personal,
                    paced("Session", used: 27, elapsed: 25 * 60 / (5 * hour), period: session),
                    paced("Weekly", used: 76, elapsed: 5.5 / 7),
                    paced("Steady", used: 40, elapsed: 0.5)),
            account(chatGPT, paced("Weekly", used: 9, elapsed: 6 * hour / (7 * day)), WidgetData(title: "Credits", kind: .dollars, used: 80, limit: 100)),
        ]

        let board = PriorityBoard.make(accounts: accounts, burningFast: BurningFast(), now: now)

        XCTAssertEqual(ids(board.attention), ["claude@1.Session", "claude@1.Weekly", "codex@1.Weekly", "codex@1.Credits"],
                       "soonest to run out first, whatever is left, then what has no pace")
        XCTAssertEqual(board.attention.map(\.reason.severity), [.normal, .warning, .normal, .warning], "the ring keeps meaning what's left")
        XCTAssertEqual(board.attention.map { $0.runOutText(now: now) }, ["Out in 1h 8m", nil, "Out in 2d 12h", nil],
                       "only a limit listed for burning fast says when it runs out")
        XCTAssertEqual(MenuBarContentBuilder.build(board: board, limit: .upToTwo).items.map(\.id), ["claude@1.Session", "claude@1.Weekly"])

        let off = PriorityBoard.make(accounts: accounts, burningFast: nil, now: now)
        XCTAssertEqual(ids(off.attention), ["claude@1.Weekly", "codex@1.Credits"], "with the setting off only low limits are listed")
    }

    func testAPinnedLimitBurningFastMovesToRunningOut() {
        let accounts = [account(personal, paced("Weekly", used: 60, elapsed: 0.5))]
        let board = PriorityBoard.make(accounts: accounts, pinned: ["claude@1.Weekly"], burningFast: BurningFast(), now: now)
        XCTAssertEqual(ids(board.attention), ["claude@1.Weekly"])
        XCTAssertEqual(board.attention.map(\.isPinned), [true])
        XCTAssertTrue(board.pinned.isEmpty)
        XCTAssertFalse(board.showsClearRow)
    }

    func testABurningLimitStaysListedUntilItsPaceEasesToNinetyPercent() {
        let nearlyEven = account(personal, paced("Weekly", used: 47.5, elapsed: 0.5))
        let eased = account(personal, paced("Weekly", used: 42.5, elapsed: 0.5))
        let latched = BurningFast(latched: ["claude@1.Weekly": now.addingTimeInterval(week / 2)])

        XCTAssertTrue(PriorityBoard.make(accounts: [nearlyEven], burningFast: BurningFast(), now: now).attention.isEmpty,
                      "95% of the limit by reset doesn't start listing it")
        XCTAssertEqual(ids(PriorityBoard.make(accounts: [nearlyEven], burningFast: latched, now: now).attention), ["claude@1.Weekly"],
                       "but keeps one listed that was burning")
        XCTAssertTrue(PriorityBoard.make(accounts: [eased], burningFast: latched, now: now).attention.isEmpty, "85% lets it go")
    }

    func testTheStoreRemembersWhatWasBurningAtItsLastReadingAndTheSettingDefaultsToOn() {
        let descriptor = WidgetDescriptor.percent(key: "weekly", provider: personal, title: "Weekly")
        let group = ProviderMetrics(provider: personal, metrics: [descriptor])
        let defaults = isolatedDefaults()
        let clock = TestClock(now)
        let store = WidgetDataStore.forTesting(
            [], registry: WidgetRegistry(providers: [personal], descriptors: [descriptor]), defaults: defaults, now: { clock.now }
        )
        let start = now.addingTimeInterval(-week / 2)
        func read(_ used: Double = 60, window: Double = 0) {
            store.snapshots[personal.id] = ProviderSnapshot(
                provider: personal, plan: nil,
                lines: [.percent("Weekly", used, resetsAt: start.addingTimeInterval((window + 1) * week), periodMs: Int(week * 1000))],
                refreshedAt: clock.now
            )
        }
        func listed() -> [PriorityItem] { store.priorityBoard(in: [group], now: clock.now).attention }

        XCTAssertTrue(store.showsBurningFast)
        read()
        XCTAssertEqual(listed().map(\.id), [descriptor.id], "60% used halfway through the week")
        XCTAssertEqual(listed().first?.runOutText(now: clock.now), "Out in 2d 8h")

        clock.set(start.addingTimeInterval(0.63 * week))
        XCTAssertEqual(listed().map(\.id), [descriptor.id], "its pace eased to 95% with no new usage: still listed")
        XCTAssertNil(listed().first?.runOutText(now: clock.now), "it would no longer run out before the reset, so the row shows the reset")

        clock.set(start.addingTimeInterval(0.72 * week))
        XCTAssertTrue(listed().isEmpty, "83% lets it go")
        read()
        clock.set(start.addingTimeInterval(0.63 * week))
        XCTAssertTrue(listed().isEmpty, "a reading taken once it eased forgets it was burning")

        clock.set(now)
        read()
        clock.set(start.addingTimeInterval(1.5 * week))
        read(47, window: 1)
        XCTAssertTrue(listed().isEmpty, "a new window at 94% of the limit doesn't inherit the last one burning")

        clock.set(now)
        store.showsBurningFast = false
        XCTAssertTrue(listed().isEmpty)
        let relaunched = WidgetDataStore.forTesting([], defaults: defaults)
        XCTAssertFalse(relaunched.showsBurningFast, "the switch survives a relaunch")
    }
}

import XCTest
@testable import OpenUsage

/// Unify Multiple Accounts, read against Robin's five Claude accounts as his card showed them on Nov 10.
@MainActor
final class UnifiedAccountsTests: QuietWindowTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 24 * 3600

    private func limit(_ title: String, left: Double, resetsIn: TimeInterval? = nil) -> WidgetData {
        var data = WidgetData(title: title, kind: .percent, used: 100 - left, limit: 100, displayMode: .remaining)
        data.resetsAt = resetsIn.map(now.addingTimeInterval)
        data.periodDurationMs = Int(7 * day * 1000)
        return data
    }

    private func resets(_ count: Int) -> WidgetData {
        var data = WidgetData(title: "Limit Resets", kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: Double(count), kind: .count, label: "available")]
        data.expiriesAt = (1...count).map { now.addingTimeInterval(Double($0) * day) }
        data.showsResetExpiries = true
        return data
    }

    private func family(_ accounts: [(label: String, readings: [(key: String, data: WidgetData)])]) -> DashboardFamily {
        let groups = accounts.enumerated().map { index, account in
            let provider = Provider(id: "claude@\(index + 1)", kind: .claude, accountLabel: account.label)
            return ProviderMetrics(
                provider: provider,
                metrics: account.readings.map { WidgetDescriptor(provider: provider, key: $0.key, metricLabel: $0.data.title, sample: $0.data) },
                unifiesAccounts: true
            )
        }
        return DashboardFamily.make(groups: groups) { DashboardLine(descriptor: $0, data: $0.sample) }[0]
    }

    private var robins: DashboardFamily {
        family([
            ("Personal", [("weekly", limit("Weekly", left: 64, resetsIn: 14 * hour + 32 * 60)),
                          ("fable", limit("Fable", left: 48, resetsIn: 14 * hour + 32 * 60)),
                          ("resets", resets(4))]),
            ("AM1", [("session", limit("Session", left: 100)),
                     ("weekly", limit("Weekly", left: 0, resetsIn: day + 17 * hour)),
                     ("fable", limit("Fable", left: 37, resetsIn: day + 17 * hour)),
                     ("resets", resets(1))]),
            ("AM2", [("session", limit("Session", left: 100)),
                     ("weekly", limit("Weekly", left: 0, resetsIn: 5 * day + 4 * hour)),
                     ("fable", limit("Fable", left: 0, resetsIn: 5 * day + 4 * hour)),
                     ("resets", resets(1))]),
            ("AM3", [("session", limit("Session", left: 67, resetsIn: 3 * hour + 12 * 60)),
                     ("weekly", limit("Weekly", left: 94, resetsIn: 5 * day + 7 * hour)),
                     ("fable", limit("Fable", left: 96, resetsIn: 5 * day + 7 * hour))]),
            ("AM4", [("session", limit("Session", left: 81, resetsIn: 3 * hour + 40 * 60)),
                     ("weekly", limit("Weekly", left: 96, resetsIn: 6 * day + 9 * hour)),
                     ("fable", limit("Fable", left: 98, resetsIn: 6 * day + 9 * hour))]),
        ])
    }

    private func line(_ key: String, in family: DashboardFamily) -> DashboardLine {
        family.accounts[0].lines.first { $0.descriptor.key == key }!
    }

    func testEachLimitShowsOnceAveragedOverTheAccountsThatHaveIt() {
        let family = robins
        XCTAssertEqual(family.accounts.count, 1)
        XCTAssertEqual(family.accounts[0].name, "5 Accounts")
        XCTAssertEqual(family.accounts[0].lines.map(\.descriptor.key), ["session", "weekly", "fable", "resets"],
                       "an account without Session keeps the others' order")
        XCTAssertEqual(line("session", in: family).members.map(\.provider.accountName), ["AM1", "AM2", "AM3", "AM4"])
        XCTAssertEqual(line("session", in: family).data.valueText, "87%", "Personal has no Session, so it counts four accounts")
        XCTAssertEqual(line("weekly", in: family).data.valueText, "51%")
        XCTAssertEqual(line("fable", in: family).data.valueText, "56%")
    }

    func testTheRedEndIsTheShareHeldByUsedUpAccounts() {
        let family = robins
        XCTAssertEqual(line("weekly", in: family).usedUpShare, 0.4, accuracy: 0.0001, "AM1 and AM2, two of five")
        XCTAssertEqual(line("fable", in: family).usedUpShare, 0.2, accuracy: 0.0001)
        XCTAssertEqual(line("session", in: family).usedUpShare, 0)

        let weekly = line("weekly", in: family).dashboardRow(now: now)
        XCTAssertEqual(weekly.usedUp?.lowerBound ?? 0, 0.6, accuracy: 0.0001, "Left fills from the start, so the red sits at the end")
        XCTAssertEqual(weekly.usedUp?.upperBound, 1)
        XCTAssertNil(line("session", in: family).dashboardRow(now: now).usedUp)
    }

    func testTheCountdownIsTheNextResetOfAnyAccount() {
        let family = robins
        XCTAssertEqual(line("session", in: family).data.compactResetText(now: now), "3h 12m", "AM1 and AM2 have no session running")
        XCTAssertEqual(line("weekly", in: family).data.compactResetText(now: now), "14h 32m")
        XCTAssertNil(line("weekly", in: family).dashboardRow(now: now).paceMark, "a unified bar has no even pace to mark")
    }

    func testLimitResetsAddUpAndStayListedByAccount() {
        let resets = line("resets", in: robins)
        XCTAssertEqual(resets.data.resetCreditCount, 6)
        XCTAssertEqual(resets.data.unboundedFigures, ["6 available"])
        XCTAssertEqual(resets.data.expiriesAt.count, 6)
        XCTAssertEqual(resets.members.map(\.provider.id), ["claude@1", "claude@2", "claude@3"],
                       "each reset refills only its own account, so the detail claims on that account")
        XCTAssertEqual(resets.members.map(\.line.data.resetCreditCount), [4, 1, 1])
    }

    func testAUnifiedLimitIsUsedUpOnlyWhenEveryAccountIs() {
        let board = PriorityBoard.make(accounts: robins.accounts, now: now)
        XCTAssertEqual(board.usedUp.map(\.id), [], "AM1 and AM2 are used up, the others aren't")
        XCTAssertTrue(board.showsClearRow)

        let spent = family([("AM1", [("weekly", limit("Weekly", left: 0, resetsIn: day))]),
                            ("AM2", [("weekly", limit("Weekly", left: 0, resetsIn: 2 * day))])])
        let spentBoard = PriorityBoard.make(accounts: spent.accounts, now: now)
        XCTAssertEqual(spentBoard.usedUp.map(\.id), ["claude.unified.weekly"])
        XCTAssertEqual(spentBoard.usedUp[0].provider.accountName, "2 Accounts")

        let nearly = family([("AM1", [("weekly", limit("Weekly", left: 0, resetsIn: day))]),
                             ("AM2", [("weekly", limit("Weekly", left: 0, resetsIn: day))]),
                             ("AM3", [("weekly", limit("Weekly", left: 1, resetsIn: day))])])
        let nearlyBoard = PriorityBoard.make(accounts: nearly.accounts, now: now)
        XCTAssertEqual(nearlyBoard.usedUp.map(\.id), [], "a third of a percent left still isn't used up")
        XCTAssertEqual(nearlyBoard.attention.map(\.data.valueText), ["1%"])
    }

    func testPriorityAndTheMenuBarCountAUnifiedLimitOnceWithoutInitials() {
        let low = family([("AM1", [("weekly", limit("Weekly", left: 10, resetsIn: day))]),
                          ("AM2", [("weekly", limit("Weekly", left: 20, resetsIn: day))])])
        let board = PriorityBoard.make(accounts: low.accounts, pinned: ["claude@2.weekly"], now: now)
        XCTAssertEqual(board.attention.map(\.id), ["claude.unified.weekly"])
        XCTAssertTrue(board.attention[0].isPinned, "pinning one account's copy pins the unified limit")

        let strip = MenuBarContentBuilder.build(board: board, limit: .upToThree)
        XCTAssertEqual(strip.items.map(\.value), ["15%"])
        XCTAssertNil(strip.items[0].provider.badge)
    }

    func testEachAccountStillSaysWhenItNeedsTheUser() {
        let board = PriorityBoard.make(accounts: robins.accounts, now: now) { account in
            account.id == "claude@3" ? .unavailable("Sign in again.") : .current
        }
        XCTAssertEqual(board.notices.map(\.provider.id), ["claude@3"])
    }

    func testTheProviderMenuTurnsItOnAndOffWithACheckmark() {
        let sections = DashboardMenus.provider(robins)
        XCTAssertEqual(sections[0], [DashboardMenuItem(title: "Refresh", command: .refresh((1...5).map { "claude@\($0)" }))])
        XCTAssertEqual(sections[1].last, DashboardMenuItem(
            title: "Unify Multiple Accounts", command: .unifyAccounts(.claude, false), isChecked: true
        ))
    }

    func testUnifyIsSavedPerProvider() {
        let defaults = isolatedDefaults()
        XCTAssertTrue(LayoutStore(registry: .mock, defaults: defaults).setUnifiesAccounts(true, of: .claude))

        let relaunched = LayoutStore(registry: .mock, defaults: defaults)
        XCTAssertEqual(relaunched.state.unifiedProviderKinds, [.claude])
        XCTAssertEqual(relaunched.displayGroups.filter(\.unifiesAccounts).map(\.provider.kind), [.claude])

        XCTAssertTrue(relaunched.setUnifiesAccounts(false, of: .claude), "choosing it again turns it off")
        XCTAssertEqual(LayoutStore(registry: .mock, defaults: defaults).state.unifiedProviderKinds, [])
    }
}

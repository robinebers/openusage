import AppKit
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

    private func family(
        _ accounts: [(label: String, readings: [(key: String, data: WidgetData)])], waiting: Set<String> = []
    ) -> DashboardFamily {
        let groups = accounts.enumerated().map { index, account in
            let provider = Provider(id: "claude@\(index + 1)", kind: .claude, accountLabel: account.label)
            return ProviderMetrics(
                provider: provider,
                metrics: account.readings.map { WidgetDescriptor(provider: provider, key: $0.key, metricLabel: $0.data.title, sample: $0.data) },
                unifiesAccounts: true
            )
        }
        return DashboardFamily.make(groups: groups, isWaiting: { waiting.contains($0.id) }) {
            DashboardLine(descriptor: $0, data: $0.sample)
        }[0]
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

    func testTheCountdownIsTheNextResetOfAnyAccount() {
        let family = robins
        XCTAssertEqual(line("session", in: family).data.compactResetText(now: now), "3h 12m", "AM1 and AM2 have no session running")
        XCTAssertEqual(line("weekly", in: family).data.compactResetText(now: now), "14h 32m")
        XCTAssertNil(line("weekly", in: family).data.dashboardRow(now: now).paceMark, "a unified bar has no even pace to mark")
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
        XCTAssertEqual(board.pinned.map(\.id), ["claude.unified.weekly"], "pinning one account's copy pins the unified limit")
        XCTAssertTrue(board.attention.isEmpty)

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

    func testAnAccountOverItsCapDoesNotUseUpAnotherAccountsRoom() {
        let over = WidgetData(title: "Budget", kind: .dollars, used: 250, limit: 100, displayMode: .remaining)
        let fresh = WidgetData(title: "Budget", kind: .dollars, used: 0, limit: 100, displayMode: .remaining)
        let budget = line("budget", in: family([("AM1", [("budget", over)]), ("AM2", [("budget", fresh)])]))
        XCTAssertEqual(budget.data.valueText, "$100", "the second account's room is still there")
        XCTAssertEqual(budget.members.map(\.line.data.used), [250, 0], "each account keeps its own spend in the list")
    }

    func testPinAndHideReachEveryAccountsCopyEvenBeforeItsFirstReading() {
        let weekly = limit("Weekly", left: 40, resetsIn: day)
        let unified = family([("AM1", [("weekly", weekly)]), ("AM2", [("weekly", weekly)])], waiting: ["claude@2"])
        XCTAssertEqual(line("weekly", in: unified).members.map(\.provider.id), ["claude@1"])
        XCTAssertEqual(line("weekly", in: unified).metricIDs, ["claude@1.weekly", "claude@2.weekly"])
    }

    func testALimitOnlyOneAccountReportsHeadsItsAccountListOneAccount() async throws {
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface") }
        let weekly = limit("Weekly", left: 40, resetsIn: day)
        let fable = limit("Fable", left: 80, resetsIn: day)
        let unified = family([("AM1", [("weekly", weekly), ("fable", fable)]), ("AM2", [("weekly", weekly)])])
        func texts(in element: Any) -> [String] {
            guard let node = element as? NSObject else { return [] }
            let text = node.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.staticText.rawValue
                ? (node.value(forKey: "accessibilityValue") as? String ?? node.value(forKey: "accessibilityLabel") as? String) : nil
            return [text].compactMap { $0 } + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(texts)
        }
        for (key, heading) in [("fable", "1 Account"), ("weekly", "2 Accounts")] {
            let (window, host) = show(UnifiedLimitDetail(line: line(key, in: unified)))
            defer { window.close() }
            try await waitUntil { texts(in: host).contains(heading) }
            XCTAssertTrue(texts(in: host).contains(heading), "\(key) is headed \(texts(in: host))")
        }
    }

    func testEachAccountsResetsFollowThePreviousAccountsAsOneList() async throws {
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface") }
        func frames(in element: Any) -> [(text: String, frame: CGRect)] {
            guard let node = element as? NSObject else { return [] }
            let text = node.value(forKey: "accessibilityLabel") as? String ?? node.value(forKey: "accessibilityValue") as? String
            let own = text.flatMap { text in (node.value(forKey: "accessibilityFrame") as? CGRect).map { (text, $0) } }
            return [own].compactMap { $0 } + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(frames)
        }
        let resets = line("resets", in: robins)
        XCTAssertEqual(resets.members.map(\.provider.accountName), ["Personal", "AM1", "AM2"])
        let (window, host) = show(UnifiedResetsDetail(line: resets, resetClaim: { _ in nil }, showsActions: false, onPinChange: { _ in }))
        defer { window.close() }
        try await waitUntil { frames(in: host).contains { $0.text == "AM2" } }
        let shown = frames(in: host)
        for (lastRow, account) in [("Reset 4", "AM1"), ("Reset 1", "AM2")] {
            // Screen coordinates: the row above a name has the larger y.
            let header = try XCTUnwrap(shown.first { $0.text == account }?.frame, "\(account) keeps its name")
            let above = try XCTUnwrap(shown.filter { $0.text.hasPrefix(lastRow) && $0.frame.minY > header.maxY }.map(\.frame).min { $0.minY < $1.minY })
            XCTAssertLessThanOrEqual(above.minY - header.maxY, 14, "\(account) sits right under the account before it")
        }
    }

    func testCappedAndUncappedSpendingAddUpPerCurrencyAndKeepEveryAccount() {
        func capped(_ spent: Double, of cap: Double, _ currency: String) -> WidgetData {
            WidgetData(title: "Extra Usage", kind: .dollars, currencyCode: currency, used: spent, limit: cap)
        }
        var uncapped = WidgetData(title: "Extra Usage", kind: .dollars, used: 0, limit: nil)
        uncapped.values = [MetricValue(number: 5, kind: .dollars, currencyCode: "USD")]

        let mixed = line("extra", in: family([("AM1", [("extra", capped(10, of: 50, "USD"))]), ("AM2", [("extra", uncapped)])]))
        XCTAssertEqual(mixed.members.count, 2, "an uncapped account stays in the list")
        XCTAssertNil(mixed.data.limit)
        XCTAssertEqual(mixed.data.values, [MetricValue(number: 15, kind: .dollars, currencyCode: "USD")])

        let currencies = [("AM1", [("extra", capped(90, of: 100, "USD"))]), ("AM2", [("extra", capped(80, of: 100, "EUR"))])]
        let forward = line("extra", in: family(currencies)).data
        let backward = line("extra", in: family(currencies.reversed())).data
        XCTAssertNil(forward.limit, "caps in two currencies have no total")
        XCTAssertEqual(Set(forward.values.map(\.currencyCode)), ["USD", "EUR"])
        XCTAssertEqual(Set(forward.values.map(\.number)), Set(backward.values.map(\.number)))
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

    func testTheBadgeShowsTheSharedPlanOrMultiple() {
        let defaults = isolatedDefaults()
        let dataStore = AppContainer.forTesting(accounts: AccountStore(defaults: defaults, vault: InMemoryCredentialVault()), defaults: defaults).dataStore
        let unified = robins.accounts[0]
        func plans(_ plans: [String?]) -> String? {
            for (index, plan) in plans.enumerated() {
                let id = "claude@\(index + 1)"
                dataStore.snapshots[id] = ProviderSnapshot(providerID: id, displayName: "Claude", plan: plan, lines: [])
            }
            return dataStore.plan(of: unified)
        }
        XCTAssertEqual(plans(Array(repeating: "Team 5x", count: 5)), "Team 5x")
        XCTAssertEqual(plans(["Ultra", "Team 5x", "Team 5x", "Team 5x", "Team 5x"]), "Multiple")
        XCTAssertEqual(plans(["Team 5x", nil, "Team 5x", nil, "Team 5x"]), "Team 5x", "an account with no plan doesn't make it Multiple")
        XCTAssertNil(plans(Array(repeating: nil, count: 5)), "no plan, no badge")
    }

    func testOnlyClaudeAndChatGPTCanBeUnified() {
        let defaults = isolatedDefaults()
        LayoutPersistence(defaults: defaults).save(LayoutState(unifiedProviderKinds: [.claude, .cursor]))
        XCTAssertEqual(LayoutStore(registry: .mock, defaults: defaults).state.unifiedProviderKinds, [.claude],
                       "a provider saved by an earlier build stops unifying")
    }
}

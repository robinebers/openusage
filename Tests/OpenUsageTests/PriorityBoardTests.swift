import XCTest
@testable import OpenUsage

@MainActor
final class PriorityBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 24 * 3600
    private var week: TimeInterval { 7 * day }

    private let chatGPT = Provider(id: "codex@1", kind: .codex, accountLabel: "ChatGPT")
    private let personal = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let work = Provider(id: "claude@2", kind: .claude, accountLabel: "Work")

    private func paced(_ title: String, used: Double, left: TimeInterval, period: TimeInterval? = nil) -> WidgetData {
        var data = WidgetData(title: title, kind: .percent, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(left)
        data.periodDurationMs = Int((period ?? week) * 1000)
        return data
    }

    private func unpaced(_ title: String, used: Double, limit: Double = 100) -> WidgetData {
        WidgetData(title: title, kind: .dollars, used: used, limit: limit)
    }

    private func account(_ provider: Provider, _ lines: WidgetData...) -> DashboardAccount {
        DashboardAccount(provider: provider, lines: lines.map { data in
            DashboardLine(
                descriptor: WidgetDescriptor(provider: provider, key: data.title, metricLabel: data.title, sample: data),
                data: data
            )
        })
    }

    private func board(_ accounts: DashboardAccount...) -> PriorityBoard {
        PriorityBoard.make(accounts: accounts, now: now)
    }

    private func ids(_ items: [PriorityItem]) -> [String] { items.map(\.id) }

    func testALimitIsListedAt30PercentLeftHoweverSlowOrFastItIsBurning() {
        let result = board(
            account(personal,
                    paced("At 30%, Nearly Reset", used: 70, left: hour),
                    paced("At 30%, Fresh", used: 70, left: 6.9 * day),
                    paced("More Than 30%, Burning Fast", used: 69, left: 6.9 * day))
        )

        XCTAssertEqual(Set(ids(result.attention)), ["claude@1.At 30%, Nearly Reset", "claude@1.At 30%, Fresh"])
    }

    func testTheClockNeverChangesWhatIsListed() {
        let accounts = [account(personal, paced("Weekly", used: 75, left: 4 * day), paced("Fable", used: 40, left: 4 * day))]
        for later in [0, hour, day, 3 * day] {
            let result = PriorityBoard.make(accounts: accounts, now: now.addingTimeInterval(later))
            XCTAssertEqual(ids(result.attention), ["claude@1.Weekly"], "\(later) seconds later")
        }
    }

    func testOrangeAt30PercentLeftAndRedAtATenthLeft() {
        func severity(_ used: Double) -> WidgetData.MeterSeverity? {
            board(account(personal, unpaced("Credits", used: used))).attention.first?.reason.severity
        }
        XCTAssertNil(severity(69))
        XCTAssertEqual(severity(70), .warning)
        XCTAssertEqual(severity(89), .warning)
        XCTAssertEqual(severity(90), .critical)
    }

    func testTheSoonestToRunOutComesFirstWhateverIsLeft() {
        let result = board(account(personal,
                                   paced("Weekly", used: 75, left: 3.5 * day),
                                   paced("Session", used: 75, left: 2.5 * hour, period: 5 * hour),
                                   unpaced("Extra Usage", used: 95)))

        XCTAssertEqual(ids(result.attention), ["claude@1.Session", "claude@1.Weekly", "claude@1.Extra Usage"],
                       "a limit with no pace to tell by follows the ones that have one")
    }

    func testEqualRanksKeepTheSavedOrder() {
        let limit = paced("Weekly", used: 75, left: 3.5 * day)
        XCTAssertEqual(ids(board(account(personal, limit), account(work, limit)).attention), ["claude@1.Weekly", "claude@2.Weekly"])
        XCTAssertEqual(ids(board(account(work, limit), account(personal, limit)).attention), ["claude@2.Weekly", "claude@1.Weekly"])

        let level = unpaced("Credits", used: 80)
        XCTAssertEqual(ids(board(account(work, level), account(personal, level)).attention), ["claude@2.Credits", "claude@1.Credits"])
    }

    func testLimitsWithNoPaceFollowThePacedOnesLeastLeftFirst() {
        let result = board(
            account(personal, unpaced("Warning", used: 80), unpaced("Critical", used: 95), unpaced("Fine", used: 40)),
            account(work, unpaced("Warned More", used: 170, limit: 200), paced("Paced", used: 75, left: 3.5 * day))
        )

        XCTAssertEqual(ids(result.attention), ["claude@2.Paced", "claude@1.Critical", "claude@2.Warned More", "claude@1.Warning"])
        XCTAssertEqual(result.attention.map(\.reason.severity), [.warning, .critical, .warning, .warning])
    }

    func testTheLevelOrderIgnoresTheUsedOrLeftSetting() {
        var most = unpaced("Most", used: 95)
        var least = unpaced("Least", used: 80)
        most.displayMode = .remaining
        least.displayMode = .remaining
        XCTAssertEqual(ids(board(account(personal, least, most)).attention), ["claude@1.Most", "claude@1.Least"])
    }

    func testUsedUpLimitsSortBySoonestResetWithNoResetLastAndNeverNeedAttention() {
        let result = board(
            account(personal, unpaced("No Reset", used: 100), paced("Later", used: 100, left: 2 * day)),
            account(work, paced("Sooner", used: 100, left: 3 * hour), paced("Running Out", used: 75, left: 3.5 * day))
        )

        XCTAssertEqual(ids(result.usedUp), ["claude@2.Sooner", "claude@1.Later", "claude@1.No Reset"])
        XCTAssertEqual(ids(result.attention), ["claude@2.Running Out"])
        XCTAssertEqual(result.usedUp[1].reason, .usedUp(resetsAt: now.addingTimeInterval(2 * day)))
    }

    func testHealthyQuietUnreportedAndUnboundedLinesAreNotListed() {
        var unreported = paced("Unreported", used: 60, left: 3.5 * day)
        unreported.hasData = false
        var balance = WidgetData(title: "Balance", kind: .dollars, used: 0, limit: nil)
        balance.values = [MetricValue(number: 12, kind: .dollars, label: nil)]

        let result = board(account(personal, paced("Healthy", used: 20, left: 3.5 * day), unpaced("Quiet", used: 10), unreported, balance))

        XCTAssertTrue(result.attention.isEmpty)
        XCTAssertTrue(result.usedUp.isEmpty)
    }

    private func realLine(_ kind: ProviderKind, _ key: String, values: [MetricValue], expiries: [Date] = []) throws -> DashboardLine {
        let descriptor = try XCTUnwrap(realDescriptors(kind).first { $0.key == key }, "\(kind) has no \(key)")
        var data = descriptor.sample
        data.values = values
        data.expiriesAt = expiries
        data.limit = nil
        return DashboardLine(descriptor: descriptor, data: data)
    }

    private func realDescriptors(_ kind: ProviderKind, organization: String? = nil) -> [WidgetDescriptor] {
        AccountProviderRuntime.widgetDescriptors(for: Account(kind: kind, label: kind.displayName, organization: organization))
    }

    private func zero(_ kind: MetricKind, label: String? = nil) -> MetricValue {
        MetricValue(number: 0, kind: kind, label: label)
    }

    func testExactlyTheseMetricsAreBalances() {
        var balances: [String] = []
        for kind in ProviderKind.allCases {
            for descriptor in realDescriptors(kind) + (kind == .copilot ? realDescriptors(kind, organization: "acme") : []) {
                var data = descriptor.sample
                data.limit = nil
                data.values = [zero(.dollars), zero(.count, label: "credits"), zero(.count, label: "available"), zero(.count)]
                if descriptor.balance(in: data) != nil { balances.append(descriptor.kindScopedKey) }
            }
        }
        XCTAssertEqual(balances.sorted(), ["codex.credits", "cursor.credits", "devin.extra", "ollama.purchasedCredits", "openrouter.balance"])
    }

    func testAnOpenBalanceAtZeroIsUsedUpAndShowsItsAmountInsteadOfATime() throws {
        let cursor = try realLine(.cursor, "credits", values: [zero(.dollars)])
        let codex = try realLine(.codex, "credits", values: [zero(.dollars), zero(.count, label: "credits")])
        let result = PriorityBoard.make(accounts: [
            DashboardAccount(provider: personal, lines: [cursor]),
            DashboardAccount(provider: chatGPT, lines: [codex]),
        ], now: now)

        XCTAssertTrue(result.attention.isEmpty, "a balance has no pace or limit to run toward")
        XCTAssertEqual(result.usedUp.map(\.id), [cursor.id, codex.id])
        XCTAssertEqual(result.usedUp.map { $0.usedUpNote(now: now) }, ["$0 left", "$0"])
        XCTAssertEqual(result.usedUp.map(\.reason.severity), [.critical, .critical])
        XCTAssertEqual(result.summary, .listed)
        XCTAssertTrue(MenuBarContentBuilder.build(board: result, limit: .upToFive).isEmpty, "a balance never reaches the menu bar")
    }

    func testAnEmptyBalanceRanksAfterEveryLimitWithAReset() throws {
        let balance = try realLine(.openrouter, "balance", values: [zero(.dollars)])
        let result = PriorityBoard.make(accounts: [
            DashboardAccount(provider: personal, lines: [balance]),
            account(work, paced("Later", used: 100, left: 20 * day), paced("Sooner", used: 100, left: hour)),
        ], now: now)

        XCTAssertEqual(result.usedUp.map(\.id), ["claude@2.Sooner", "claude@2.Later", balance.id])
    }

    func testAPinnedEmptyBalanceIsListedOnlyUnderUsedUp() throws {
        let balance = try realLine(.openrouter, "balance", values: [zero(.dollars)])
        let healthy = paced("Weekly", used: 10, left: day)
        let result = PriorityBoard.make(accounts: [
            DashboardAccount(provider: personal, lines: [balance]), account(work, healthy),
        ], pinned: [balance.id, "claude@2.Weekly"], now: now)

        XCTAssertEqual(result.pinned.map(\.id), ["claude@2.Weekly"])
        XCTAssertEqual(ids(result.usedUp), [balance.id])
        XCTAssertEqual(result.usedUp.map(\.isPinned), [true], "its menu offers Unpin")
        XCTAssertEqual(result.summary, .listed)
        XCTAssertTrue(result.showsClearRow)

        let onlyHealthy = PriorityBoard.make(accounts: [account(work, healthy)], pinned: ["claude@2.Weekly"], now: now)
        XCTAssertEqual(onlyHealthy.summary, .allClear)
        XCTAssertTrue(onlyHealthy.hasRows, "a healthy pin alone can still be copied as a picture")
        XCTAssertFalse(PriorityBoard.make(accounts: [account(work, healthy)], now: now).hasRows)
    }

    func testAPinnedMetricRunningOutOrUsedUpIsListedOnlyThereUntilItIsNot() {
        let pins: Set<String> = ["claude@1.Session", "claude@1.Weekly", "claude@1.Monthly"]
        func pinnedBoard(sessionUsed: Double, monthlyUsed: Double) -> PriorityBoard {
            PriorityBoard.make(accounts: [account(personal,
                                                  paced("Session", used: sessionUsed, left: hour),
                                                  paced("Weekly", used: 20, left: day),
                                                  paced("Monthly", used: monthlyUsed, left: day))],
                               pinned: pins, now: now)
        }

        let runningOut = pinnedBoard(sessionUsed: 95, monthlyUsed: 100)
        XCTAssertEqual(ids(runningOut.attention), ["claude@1.Session"])
        XCTAssertEqual(runningOut.attention.map(\.isPinned), [true], "its menu offers Unpin")
        XCTAssertEqual(ids(runningOut.usedUp), ["claude@1.Monthly"])
        XCTAssertEqual(runningOut.usedUp.map(\.isPinned), [true], "so does a used-up pin's")
        XCTAssertEqual(runningOut.pinned.map(\.id), ["claude@1.Weekly"])
        XCTAssertFalse(runningOut.showsClearRow)

        let recovered = pinnedBoard(sessionUsed: 20, monthlyUsed: 0)
        XCTAssertTrue(recovered.attention.isEmpty)
        XCTAssertTrue(recovered.usedUp.isEmpty)
        XCTAssertEqual(recovered.pinned.map(\.id), ["claude@1.Session", "claude@1.Weekly", "claude@1.Monthly"],
                       "back under Pinned in dashboard order")

        let allRunningOut = PriorityBoard.make(accounts: [account(personal, paced("Session", used: 95, left: hour))],
                                               pinned: ["claude@1.Session"], now: now)
        XCTAssertTrue(allRunningOut.pinned.isEmpty, "no Pinned section while every pin is running out")
        XCTAssertEqual(ids(allRunningOut.attention), ["claude@1.Session"])
    }

    func testABalanceWithAnythingLeftIsNotListed() throws {
        let cents = try realLine(.cursor, "credits", values: [MetricValue(number: 0.01, kind: .dollars)])
        let credits = try realLine(.codex, "credits", values: [MetricValue(number: 0.04, kind: .dollars), MetricValue(number: 1, kind: .count, label: "credits")])
        let result = PriorityBoard.make(accounts: [DashboardAccount(provider: personal, lines: [cents, credits])], now: now)

        XCTAssertTrue(result.attention.isEmpty)
        XCTAssertTrue(result.usedUp.isEmpty)
    }

    func testABalanceMeasuredAgainstALimitFollowsTheLimitRules() throws {
        let descriptor = try XCTUnwrap(realDescriptors(.cursor).first { $0.key == "credits" })
        var low = unpaced("Credits", used: 90)
        low.values = [zero(.dollars)]
        let result = PriorityBoard.make(accounts: [DashboardAccount(provider: personal, lines: [DashboardLine(descriptor: descriptor, data: low)])], now: now)

        XCTAssertEqual(result.attention.map(\.reason), [.low(.critical, remaining: 0.1, runway: nil)])
        XCTAssertTrue(result.usedUp.isEmpty)
    }

    func testNothingButABalanceReachesUsedUpAtZero() {
        for kind in ProviderKind.allCases {
            for descriptor in realDescriptors(kind) + (kind == .copilot ? realDescriptors(kind, organization: "acme") : [])
            where !["codex.credits", "cursor.credits", "devin.extra", "ollama.purchasedCredits", "openrouter.balance"].contains(descriptor.kindScopedKey) {
                var data = descriptor.sample
                data.limit = nil
                data.values = [zero(.dollars), zero(.count, label: "credits"), zero(.count, label: "available"), zero(.count)]
                let line = DashboardLine(descriptor: descriptor, data: data)
                let result = PriorityBoard.make(accounts: [DashboardAccount(provider: personal, lines: [line])], now: now)
                XCTAssertTrue(result.usedUp.isEmpty, descriptor.kindScopedKey)
                XCTAssertTrue(result.attention.isEmpty, descriptor.kindScopedKey)
            }
        }
    }

    func testSpendTotalsAndLimitResetsAtZeroAreNotUsedUp() throws {
        let lines = try [
            realLine(.openrouter, "today", values: [zero(.dollars)]),
            realLine(.cursor, "last30", values: [zero(.dollars), zero(.count, label: "tokens")]),
            realLine(.copilot, "extra", values: [zero(.count)]),
            realLine(.claude, "rateLimitResets", values: [zero(.count, label: "available")]),
            realLine(.codex, "rateLimitResets", values: [zero(.count, label: "available")], expiries: [now.addingTimeInterval(day)]),
        ]
        XCTAssertNotNil(lines.first { $0.descriptor.limitResources.contains { $0.kind == .balance } }, "Limit Resets export as a balance and still don't count")

        let result = PriorityBoard.make(accounts: [DashboardAccount(provider: personal, lines: lines)], now: now)

        XCTAssertTrue(result.usedUp.isEmpty)
        XCTAssertTrue(result.attention.isEmpty)
    }

    func testAUsedUpLimitsNoteIsTheBareTimeUntilItResets() {
        var limit = paced("Weekly", used: 100, left: 22 * hour + 10 * 60)
        var result = board(account(personal, limit))
        XCTAssertEqual(result.usedUp[0].usedUpNote(now: now), "22h 10m")

        limit.resetDisplayMode = .absolute
        result = board(account(personal, limit))
        XCTAssertEqual(result.usedUp[0].usedUpNote(now: now), Formatters.compactClock(now.addingTimeInterval(22 * hour + 10 * 60), now: now))

        limit.resetDisplayMode = .relative
        limit.resetsAt = now.addingTimeInterval(-1)
        limit.periodDurationMs = nil
        result = board(account(personal, limit))
        XCTAssertEqual(result.usedUp[0].usedUpNote(now: now), "soon")

        XCTAssertNil(board(account(personal, unpaced("Credits", used: 100))).usedUp[0].usedUpNote(now: now))
    }

    func testTheSummarySaysWhetherThereIsAnythingToReport() {
        var unreported = paced("Unreported", used: 60, left: 3.5 * day)
        unreported.hasData = false
        var balance = WidgetData(title: "Balance", kind: .dollars, used: 0, limit: nil)
        balance.values = [MetricValue(number: 12, kind: .dollars, label: nil)]

        XCTAssertEqual(board().summary, .waitingForUsage)
        XCTAssertEqual(board(account(personal)).summary, .waitingForUsage)
        XCTAssertEqual(board(account(personal, unreported, balance)).summary, .noReportedLimits)
        XCTAssertEqual(board(account(personal, unpaced("Quiet", used: 10))).summary, .allClear)
        XCTAssertEqual(board(account(personal, unpaced("Spent", used: 100))).summary, .listed)
        XCTAssertEqual(board(account(personal, unpaced("Warning", used: 80))).summary, .listed)
    }

    func testAReportedAccountDoesNotWaitForALimitItWillNeverHave() throws {
        let org = Account(kind: .copilot, label: "Acme", organization: "acme")
        let provider = AccountProviderRuntime.provider(for: org)
        let group = ProviderMetrics(provider: provider, metrics: AccountProviderRuntime.widgetDescriptors(for: org))
        let clock = TestClock(now)
        let store = WidgetDataStore.forTesting([], defaults: isolatedDefaults(), now: { clock.now })
        func summary() -> PriorityBoard.Summary { store.priorityBoard(in: [group], now: clock.now).summary }

        XCTAssertEqual(summary(), .waitingForUsage)
        store.snapshots[provider.id] = ProviderSnapshot(provider: provider, plan: nil, lines: [], refreshedAt: now)
        XCTAssertEqual(summary(), .noReportedLimits)
        store.snapshots[provider.id]?.lines = [.values(label: "Org Spend", values: [MetricValue(number: 25, kind: .dollars)])]
        XCTAssertEqual(summary(), .noReportedLimits)
        clock.set(now.addingTimeInterval(RefreshSetting.stalenessThreshold + 1))
        XCTAssertEqual(summary(), .noReportedLimits, "old values still waiting for their next read are not a problem")
    }

    func testFailedRefreshIsVisibleBesideOtherAlertsAndSharesWithoutAccountDetails() async throws {
        let email = "private@example.com"
        let provider = Provider(id: "claude@1", kind: .claude, accountLabel: email)
        let weekly = WidgetDescriptor.percent(key: "weekly", provider: provider, title: "Weekly")
        let other = WidgetDescriptor.percent(key: "weekly", provider: work, title: "Weekly")
        let failure = RefreshFailure(message: "Replace the token for \(email).", kind: .refused)
        let runtime = StubRuntime(provider: provider, descriptors: [weekly], failure: failure)
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { self.now })
        let groups = [ProviderMetrics(provider: provider, metrics: [weekly]), ProviderMetrics(provider: work, metrics: [other])]
        _ = await store.refresh(providerID: provider.id, force: true)
        XCTAssertEqual(store.priorityBoard(in: [groups[0]], now: now).summary, .unavailable)

        store.snapshots[provider.id] = ProviderSnapshot(provider: provider, plan: nil, lines: [.percent("Weekly", 15)], refreshedAt: now)
        store.snapshots[work.id] = ProviderSnapshot(provider: work, plan: nil, lines: [.percent("Weekly", 75)], refreshedAt: now)
        let live = store.priorityBoard(in: groups, now: now)
        XCTAssertEqual(live.summary, .listed)
        XCTAssertEqual(live.attention.map(\.id), [other.id])
        XCTAssertEqual(live.notices.map(\.message), [failure.message])
        XCTAssertFalse(live.showsClearRow)
        let shared = store.priorityBoard(in: groups, now: now, hidingEmails: true)
        let notice = try XCTUnwrap(shared.notices.first)
        XCTAssertFalse(notice.provider.fullName.contains(email))
        XCTAssertFalse(notice.message.contains(email))
    }

    func testEachAccountWithoutAReadingWaitsInItsOwnRowBesideWhatHasReported() {
        let firstLaunch = board(account(personal), account(chatGPT))
        XCTAssertEqual(firstLaunch.waiting.map(\.id), [personal.id, chatGPT.id])
        XCTAssertEqual(firstLaunch.summary, .waitingForUsage)
        XCTAssertFalse(firstLaunch.showsClearRow)

        let mixed = board(account(personal, unpaced("Warning", used: 80)), account(chatGPT))
        XCTAssertEqual(ids(mixed.attention), ["claude@1.Warning"])
        XCTAssertEqual(mixed.waiting.map(\.id), [chatGPT.id], "a pending account still shows while another is running out")
        let quiet = board(account(personal, unpaced("Quiet", used: 10)), account(chatGPT))
        XCTAssertEqual(quiet.waiting.map(\.id), [chatGPT.id])
        XCTAssertFalse(quiet.showsClearRow, "All Clear can't speak for an account that hasn't reported")

        let reported = board(account(personal, unpaced("Warning", used: 80)), account(chatGPT, unpaced("Quiet", used: 10)))
        XCTAssertTrue(reported.waiting.isEmpty)
        XCTAssertEqual(reported.summary, .listed)
    }

    func testAnAccountIsASkeletonOnBothTabsUntilItsFirstReadingAndAFailureIsNot() async {
        let session = WidgetDescriptor.percent(key: "session", provider: personal, title: "Session")
        let weekly = WidgetDescriptor.percent(key: "weekly", provider: personal, title: "Weekly")
        let codex = WidgetDescriptor.percent(key: "weekly", provider: chatGPT, title: "Weekly")
        let broken = WidgetDescriptor.percent(key: "weekly", provider: work, title: "Weekly")
        let failure = RefreshFailure(message: "Replace the token.", kind: .refused)
        let runtime = StubRuntime(provider: work, descriptors: [broken], failure: failure)
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { self.now })
        let groups = [
            ProviderMetrics(provider: personal, metrics: [session, weekly]),
            ProviderMetrics(provider: chatGPT, metrics: [codex]),
            ProviderMetrics(provider: work, metrics: [broken]),
        ]
        _ = await store.refresh(providerID: work.id, force: true)
        func skeletons() -> [[String]] { store.accounts(in: groups).map(\.waitingMetricIDs) }

        let firstLaunch = store.priorityBoard(in: groups, now: now)
        XCTAssertEqual(firstLaunch.waiting.map(\.id), [personal.id, chatGPT.id])
        XCTAssertEqual(firstLaunch.notices.map(\.provider.id), [work.id])
        XCTAssertEqual(skeletons(), [[session.id, weekly.id], [], [codex.id]], "Work shares Claude's card, ahead of ChatGPT")

        store.snapshots[personal.id] = ProviderSnapshot(provider: personal, plan: nil, lines: [.percent("Weekly", 80)], refreshedAt: now)
        let mixed = store.priorityBoard(in: groups, now: now)
        XCTAssertEqual(mixed.attention.map(\.id), [weekly.id])
        XCTAssertEqual(mixed.waiting.map(\.id), [chatGPT.id])
        XCTAssertEqual(skeletons(), [[], [], [codex.id]])

        store.snapshots[chatGPT.id] = ProviderSnapshot(provider: chatGPT, plan: nil, lines: [.percent("Weekly", 10)], refreshedAt: now)
        XCTAssertTrue(store.priorityBoard(in: groups, now: now).waiting.isEmpty)
        XCTAssertEqual(skeletons(), [[], [], []])
    }
}

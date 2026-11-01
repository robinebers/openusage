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

    func testAProjectionOverTheLimitOutranksAMoreUsedLimitThatStaysUnderIt() {
        let result = board(
            account(personal,
                    paced("Fable", used: 47, left: 3 * day + 8 * hour),
                    paced("Weekly", used: 51, left: 3 * day + 8 * hour)),
            account(chatGPT, paced("Weekly", used: 31, left: 5 * day))
        )

        XCTAssertEqual(ids(result.attention), ["codex@1.Weekly", "claude@1.Weekly"],
                       "108% projected beats 97% projected, and 89% projected isn't listed")
        guard case .runningOut = result.attention[0].reason else { return XCTFail("\(result.attention[0].reason)") }
        guard case .closeToLimit = result.attention[1].reason else { return XCTFail("\(result.attention[1].reason)") }
    }

    func testRunningOutOutranksCloseToLimitWhateverTheRunway() {
        let result = board(
            account(personal, paced("Session", used: 48, left: 2.5 * hour, period: 5 * hour)),
            account(work, paced("Weekly", used: 60, left: 3.5 * day))
        )

        let session = result.attention.last
        XCTAssertLessThan(try XCTUnwrap(session?.data.runway(now: now)), try XCTUnwrap(result.attention.first?.data.runway(now: now)))
        XCTAssertEqual(ids(result.attention), ["claude@2.Weekly", "claude@1.Session"])
    }

    func testTheSoonestToHitTheLimitLeadsItsTier() {
        let runningOut = board(account(personal,
                                       paced("Weekly", used: 55, left: 3.5 * day),
                                       paced("Session", used: 55, left: 2.5 * hour, period: 5 * hour)))
        XCTAssertEqual(ids(runningOut.attention), ["claude@1.Session", "claude@1.Weekly"])

        let close = board(account(personal,
                                  paced("Weekly", used: 47, left: 3.5 * day),
                                  paced("Session", used: 47, left: 2.5 * hour, period: 5 * hour)))
        XCTAssertEqual(ids(close.attention), ["claude@1.Session", "claude@1.Weekly"])
    }

    func testTheRunwayIsTheTimeLeftUntilTheLimitAtTheCurrentPace() throws {
        let weekly = paced("Weekly", used: 31, left: 5 * day)
        XCTAssertEqual(try XCTUnwrap(weekly.runway(now: now)), 69 / (31 / (2 * day)), accuracy: 1)
        XCTAssertNil(unpaced("Credits", used: 80).runway(now: now), "no window, no pace")
    }

    func testEqualRanksKeepTheSavedOrder() {
        let limit = paced("Weekly", used: 60, left: 3.5 * day)
        XCTAssertEqual(ids(board(account(personal, limit), account(work, limit)).attention), ["claude@1.Weekly", "claude@2.Weekly"])
        XCTAssertEqual(ids(board(account(work, limit), account(personal, limit)).attention), ["claude@2.Weekly", "claude@1.Weekly"])

        let level = unpaced("Credits", used: 80)
        XCTAssertEqual(ids(board(account(work, level), account(personal, level)).attention), ["claude@2.Credits", "claude@1.Credits"])
    }

    func testLevelsFollowThePacedLimitsMostUsedFirst() {
        let result = board(
            account(personal, unpaced("Warning", used: 80), unpaced("Critical", used: 95), unpaced("Fine", used: 70)),
            account(work, unpaced("Warned More", used: 170, limit: 200), paced("Paced", used: 47, left: 3.5 * day))
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
            account(work, paced("Sooner", used: 100, left: 3 * hour), paced("Running Out", used: 60, left: 3.5 * day))
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

        XCTAssertEqual(result.attention.map(\.reason), [.level(.critical, usedShare: 0.9)])
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
        XCTAssertEqual(board(account(personal, unreported, balance)).summary, .waitingForUsage, "a balance alone isn't a limit with data")
        XCTAssertEqual(board(account(personal, unpaced("Quiet", used: 10))).summary, .allClear)
        XCTAssertEqual(board(account(personal, unpaced("Spent", used: 100))).summary, .listed)
        XCTAssertEqual(board(account(personal, unpaced("Warning", used: 80))).summary, .listed)
    }
}

import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarContentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let personal = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let chatGPT = Provider(id: "codex@1", kind: .codex, accountLabel: "ChatGPT")

    private func limit(_ title: String, used: Double, kind: MetricKind = .percent) -> WidgetData {
        WidgetData(title: title, kind: kind, used: used, limit: 100)
    }

    private func account(_ provider: Provider, _ lines: WidgetData...) -> DashboardAccount {
        DashboardAccount(provider: provider, lines: lines.map { data in
            DashboardLine(
                descriptor: WidgetDescriptor(provider: provider, key: data.title, metricLabel: data.title, sample: data),
                data: data
            )
        })
    }

    private func content(_ limit: MenuBarLimit, pinned: Set<String> = [], _ accounts: DashboardAccount...) -> MenuBarContent {
        MenuBarContentBuilder.build(board: PriorityBoard.make(accounts: accounts, pinned: pinned, now: now), limit: limit)
    }

    private func sevenLimits() -> DashboardAccount {
        account(personal, limit("A", used: 99), limit("B", used: 98), limit("C", used: 97), limit("D", used: 96),
                limit("E", used: 95), limit("F", used: 94), limit("G", used: 93))
    }

    func testTheMostUrgentLimitsShowUpToTheSettingAndTheRestBecomeTheOverflow() {
        let cases: [(MenuBarLimit, [String], Int)] = [
            (.upToOne, ["A"], 6),
            (.upToTwo, ["A", "B"], 5),
            (.upToThree, ["A", "B", "C"], 4),
            (.upToFour, ["A", "B", "C", "D"], 3),
            (.upToFive, ["A", "B", "C", "D", "E"], 2),
        ]
        for (setting, labels, overflow) in cases {
            let strip = content(setting, sevenLimits())
            XCTAssertEqual(strip.items.map(\.shortLabel), labels, setting.label)
            XCTAssertEqual(strip.overflow, overflow, setting.label)
        }
    }

    func testTheStripReranksAtResetEvenWithoutANewReading() {
        var session = limit("Session", used: 75)
        session.resetsAt = now.addingTimeInterval(20)
        session.periodDurationMs = 5 * 60 * 60 * 1_000
        let accounts = [account(personal, session, limit("Budget", used: 95))]
        let before = PriorityBoard.make(accounts: accounts, now: now)
        let after = PriorityBoard.make(accounts: accounts, now: now.addingTimeInterval(30))

        XCTAssertTrue(before.requiresRankingClock(at: now))
        XCTAssertEqual(MenuBarContentBuilder.build(board: before, limit: .upToOne).items.first?.label, "Session")
        XCTAssertFalse(after.requiresRankingClock(at: now.addingTimeInterval(30)))
        XCTAssertEqual(MenuBarContentBuilder.build(board: after, limit: .upToOne).items.first?.label, "Budget")
        let single = PriorityBoard.make(accounts: [account(personal, session)], now: now)
        XCTAssertFalse(single.requiresRankingClock(at: now))
    }

    func testIconOnlyShowsNoLimitsAndNoOverflow() {
        let strip = content(.iconOnly, sevenLimits())
        XCTAssertTrue(strip.isEmpty)
        XCTAssertEqual(strip.overflow, 0)
        XCTAssertNil(MenuBarStripRenderer.image(for: strip), "the status item falls back to the app icon")
    }

    func testNothingNeedingAttentionShowsTheAppIcon() {
        let strip = content(.upToThree, account(personal, limit("Quiet", used: 10)))
        XCTAssertEqual(strip, MenuBarContent(items: []))
    }

    func testUsedUpLimitsShowAfterRunningOutAndCountTowardTheOverflow() {
        let accounts = account(personal, limit("Spent", used: 100), limit("Spent Too", used: 100),
                               limit("Low", used: 95), limit("Lower", used: 90))
        let one = content(.upToOne, accounts)
        XCTAssertEqual(one.items.map(\.shortLabel), ["Low"])
        XCTAssertEqual(one.overflow, 3)

        let five = content(.upToFive, accounts)
        XCTAssertEqual(five.items.map(\.shortLabel), ["Low", "Lower", "Spent", "Spent Too"])
        XCTAssertEqual(five.items.map(\.value), ["95%", "90%", "100%", "100%"])
        XCTAssertEqual(five.overflow, 0)

        var left = limit("Spent", used: 100)
        left.displayMode = .remaining
        XCTAssertEqual(content(.upToOne, account(personal, left)).items.map(\.value), ["0%"])
    }

    func testPinnedLimitsShowWithNothingRunningOut() {
        let strip = content(.upToThree, pinned: ["claude@1.Weekly", "codex@1.Session"],
                            account(personal, limit("Session", used: 10), limit("Weekly", used: 40)),
                            account(chatGPT, limit("Session", used: 20)))
        XCTAssertEqual(strip.items.map(\.id), ["claude@1.Weekly", "codex@1.Session"])
        XCTAssertEqual(strip.items.map(\.value), ["40%", "20%"])
        XCTAssertEqual(strip.overflow, 0)
    }

    func testAPinnedMetricWithoutALimitShowsItsAmount() {
        let provider = Provider(id: "openrouter", kind: .openrouter)
        let descriptor = WidgetDescriptor.values(key: "balance", provider: provider, title: "Balance")
        var data = descriptor.sample
        data.values = [MetricValue(number: 12, kind: .dollars)]
        let account = DashboardAccount(provider: provider, lines: [DashboardLine(descriptor: descriptor, data: data)])
        let board = PriorityBoard.make(accounts: [account], pinned: [descriptor.id], now: now)

        XCTAssertEqual(MenuBarContentBuilder.build(board: board, limit: .upToOne).items.map(\.value), ["$12"])
    }

    func testAPinnedLimitWithoutAReadingShowsADashAsItsRowDoes() {
        var weekly = limit("Weekly", used: 0)
        weekly.hasData = false
        let strip = content(.upToOne, pinned: ["claude@1.Weekly"], account(personal, weekly))
        XCTAssertEqual(strip.items.map(\.value), [WidgetData.noDataValue])
    }

    func testRunningOutAndUsedUpComeBeforePinsAndPinsCountTowardTheOverflow() {
        let accounts = account(personal, limit("Pin A", used: 10), limit("Spent", used: 100),
                               limit("Pin B", used: 20), limit("Low", used: 95))
        let pins: Set<String> = ["claude@1.Pin A", "claude@1.Pin B"]

        let three = content(.upToThree, pinned: pins, accounts)
        XCTAssertEqual(three.items.map(\.shortLabel), ["Low", "Spent", "Pin A"])
        XCTAssertEqual(three.overflow, 1, "Pin B waits")

        let one = content(.upToOne, pinned: pins, accounts)
        XCTAssertEqual(one.items.map(\.shortLabel), ["Low"])
        XCTAssertEqual(one.overflow, 3)
    }

    func testAPinnedLimitThatIsRunningOutShowsOnceAsRunningOut() {
        let strip = content(.upToFive, pinned: ["claude@1.Low", "claude@1.Quiet"],
                            account(personal, limit("Quiet", used: 10), limit("Low", used: 95)))
        XCTAssertEqual(strip.items.map(\.shortLabel), ["Low", "Quiet"])
        XCTAssertEqual(strip.overflow, 0)
    }

    func testUseItOrLoseItLimitsStayOut() {
        var weekly = limit("Weekly", used: 20)
        weekly.resetsAt = now.addingTimeInterval(6 * 3600)
        weekly.periodDurationMs = 7 * 24 * 3600 * 1000
        let board = PriorityBoard.make(accounts: [account(personal, weekly)], useItOrLoseIt: true, now: now)

        XCTAssertEqual(board.useItOrLoseIt.map(\.id), ["claude@1.Weekly"])
        XCTAssertEqual(MenuBarContentBuilder.build(board: board, limit: .upToFive), MenuBarContent(items: []))
    }

    func testNoAccountsShowTheAppIconEvenWithPins() {
        let strip = content(.upToThree, pinned: ["claude@1.Weekly"])
        XCTAssertEqual(strip, MenuBarContent(items: []))
        XCTAssertNil(MenuBarStripRenderer.image(for: strip), "the status item falls back to the app icon")
    }

    func testEveryItemNamesItsLimitAndCarriesItsValue() {
        var dollars = limit("Extra Usage", used: 95, kind: .dollars)
        dollars.displayMode = .remaining
        let strip = content(.upToThree, account(personal, limit("Session", used: 96), dollars))

        XCTAssertEqual(strip.items.map(\.id), ["claude@1.Session", "claude@1.Extra Usage"])
        XCTAssertEqual(strip.items.map(\.shortLabel), ["Session", "Extra"])
        XCTAssertEqual(strip.items.map(\.label), ["Session", "Extra Usage"])
        XCTAssertEqual(strip.items.map(\.value), ["96%", "$5"])
        XCTAssertEqual(strip.overflow, 0)
    }

    func testAnAccountsLimitsKeepTheirRankRatherThanGathering() {
        let strip = content(.upToThree,
                            account(personal, limit("A", used: 99), limit("C", used: 97)),
                            account(chatGPT, limit("B", used: 98)))
        XCTAssertEqual(strip.items.map(\.shortLabel), ["A", "B", "C"])
    }

    func testThePreviewShowsExactlyTheNumberPicked() {
        for limit in MenuBarLimit.allCases where limit != .iconOnly {
            let sample = PriorityIconsPreview.sample(limit: limit)
            XCTAssertEqual(sample.items.count, limit.count)
            XCTAssertGreaterThan(sample.overflow, 0, "\(limit) doesn't show the count of what's left out")
        }
        XCTAssertTrue(PriorityIconsPreview.sample(limit: .iconOnly).isEmpty)
    }

    func testThePreviewShrinksAWideStripToFitAndKeepsItsProportions() {
        let wide = PriorityIconsPreview.fittedSize(of: NSSize(width: 400, height: 24), in: 268)
        XCTAssertEqual(wide.width, 268)
        XCTAssertEqual(wide.height, 16.08, accuracy: 0.01)
    }

    func testTheShortLabelDropsATrailingGenericWordWhenAWordRemains() {
        let cases = [
            "Cursor Models": "Cursor", "Grok Bot": "Grok", "Extra USAGE": "Extra",
            "Usage": "Usage", "Usage Limit": "Usage Limit",
        ]
        for (label, short) in cases {
            XCTAssertEqual(MenuBarContentBuilder.shortLabel(label), short, label)
        }
    }

    func testAccessibilityTextReadsEveryItemInFullAndTheOverflow() {
        var models = limit("Cursor Models", used: 96)
        models.displayMode = .used
        let strip = content(.upToOne, account(chatGPT, models), account(personal, limit("Session", used: 90)))
        XCTAssertEqual(strip.accessibilityText, "\(chatGPT.fullName) Cursor Models 96%; 1 more")

        XCTAssertEqual(content(.upToThree, account(personal, limit("Session", used: 96), limit("Weekly", used: 95))).accessibilityText,
                       "\(personal.fullName) Session 96%; \(personal.fullName) Weekly 95%")
    }

    func testThePersistedSettingDefaultsToUpToThreeAndSurvivesARelaunch() {
        let defaults = isolatedDefaults()
        let store = WidgetDataStore.forTesting([], defaults: defaults)
        XCTAssertEqual(store.menuBarLimit, .upToThree)

        store.menuBarLimit = .iconOnly
        XCTAssertEqual(WidgetDataStore.forTesting([], defaults: defaults).menuBarLimit, .iconOnly)
    }

    func testALimitIsNamedAsThePanelNamesIt() {
        let provider = Provider(id: "cursor", kind: .cursor)
        let data = WidgetData(title: "Extra Usage", kind: .dollars, used: 400, limit: 500)
        let descriptor = WidgetDescriptor(provider: provider, key: "onDemand", metricLabel: "On-demand", sample: data)
        let account = DashboardAccount(provider: provider, lines: [DashboardLine(descriptor: descriptor, data: data)])
        let board = PriorityBoard.make(accounts: [account], now: Date())

        XCTAssertEqual(MenuBarContentBuilder.build(board: board, limit: .upToFive).items.map(\.shortLabel), ["Extra"])
    }
}

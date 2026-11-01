import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarContentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let personal = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let work = Provider(id: "claude@2", kind: .claude, accountLabel: "Attention Machine 1")
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

    private func content(_ limit: MenuBarLimit, _ accounts: DashboardAccount...) -> MenuBarContent {
        MenuBarContentBuilder.build(board: PriorityBoard.make(accounts: accounts, now: now), limit: limit)
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
            (.upToFive, ["A", "B", "C", "D", "E"], 2),
        ]
        for (setting, labels, overflow) in cases {
            let strip = content(setting, sevenLimits())
            XCTAssertEqual(strip.items.map(\.shortLabel), labels, setting.label)
            XCTAssertEqual(strip.overflow, overflow, setting.label)
        }
    }

    func testFewerLimitsThanTheSettingLeaveNoOverflow() {
        let strip = content(.upToFive, account(personal, limit("A", used: 99), limit("B", used: 98)))
        XCTAssertEqual(strip.items.count, 2)
        XCTAssertEqual(strip.overflow, 0)
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
        XCTAssertNil(MenuBarStripRenderer.image(for: strip))
    }

    func testUsedUpLimitsNeverShowAndNeverCountTowardTheOverflow() {
        let strip = content(.upToOne, account(personal, limit("Spent", used: 100), limit("Spent Too", used: 100),
                                              limit("Low", used: 95), limit("Lower", used: 90)))
        XCTAssertEqual(strip.items.map(\.shortLabel), ["Low"])
        XCTAssertEqual(strip.overflow, 1, "only Lower waits; Spent and Spent Too aren't running out")

        XCTAssertTrue(content(.upToThree, account(personal, limit("Spent", used: 100))).isEmpty)
    }

    func testEveryItemNamesItsLimitAndCarriesItsValue() {
        var dollars = limit("Extra Usage", used: 95, kind: .dollars)
        dollars.displayMode = .remaining
        let strip = content(.upToThree, account(personal, limit("Session", used: 96), dollars))

        XCTAssertEqual(strip.items.map(\.id), ["claude@1.Session", "claude@1.Extra Usage"])
        XCTAssertEqual(strip.items.map(\.shortLabel), ["Session", "Extra"])
        XCTAssertEqual(strip.items.map(\.label), ["Session", "Extra Usage"])
        XCTAssertEqual(strip.items.map(\.value), ["96%", "$5"])
    }

    func testAnAccountsLimitsAreSeparateItemsPastAnyPerAccountCap() {
        let strip = content(.upToThree, account(personal, limit("A", used: 99), limit("B", used: 98), limit("C", used: 97), limit("D", used: 96)))

        XCTAssertEqual(strip.items.map(\.id), ["claude@1.A", "claude@1.B", "claude@1.C"])
        XCTAssertEqual(Set(strip.items.map(\.id)).count, 3, "items of one account must not collide")
        XCTAssertEqual(strip.overflow, 1)
    }

    func testAnAccountsLimitsKeepTheirRankRatherThanGathering() {
        let strip = content(.upToThree,
                            account(personal, limit("A", used: 99), limit("C", used: 97)),
                            account(chatGPT, limit("B", used: 98)))
        XCTAssertEqual(strip.items.map(\.shortLabel), ["A", "B", "C"])
    }

    func testOnlySeveralAccountsOfAProviderAmongTheShownItemsAreBadged() {
        XCTAssertEqual(content(.upToThree, account(personal, limit("A", used: 99), limit("B", used: 98))).items.map(\.badge), [nil, nil],
                       "two limits of one account are not two accounts")

        let strip = content(.upToFive,
                            account(personal, limit("A", used: 99), limit("B", used: 96)),
                            account(work, limit("C", used: 98)),
                            account(chatGPT, limit("D", used: 97)))
        XCTAssertEqual(strip.items.map(\.shortLabel), ["A", "C", "D", "B"])
        XCTAssertEqual(strip.items.map(\.badge), ["P", "A1", nil, "P"])

        let hidden = content(.upToOne, account(personal, limit("A", used: 99)), account(work, limit("B", used: 98)))
        XCTAssertEqual(hidden.items.map(\.badge), [nil], "an account in the overflow doesn't count")
    }

    func testTheShortLabelDropsATrailingGenericWordWhenAWordRemains() {
        let cases = [
            "Cursor Models": "Cursor", "Other Models": "Other", "Grok Bot": "Grok", "Total usage": "Total",
            "Extra USAGE": "Extra", "Session": "Session", "Weekly": "Weekly", "Fable": "Fable", "Usage": "Usage",
            "Models": "Models", "Usage Limit": "Usage Limit", "Spark Weekly": "Spark Weekly",
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
        let registry = WidgetRegistry(providers: [], descriptors: [])
        let store = WidgetDataStore.forTesting([], registry: registry, defaults: defaults)
        XCTAssertEqual(store.menuBarLimit, .upToThree)

        store.menuBarLimit = .iconOnly
        XCTAssertEqual(WidgetDataStore.forTesting([], registry: registry, defaults: defaults).menuBarLimit, .iconOnly)
    }

    func testTheSettingOffersItsChoicesInOrder() {
        XCTAssertEqual(MenuBarLimit.allCases.map(\.label), ["Icon Only", "Up to 1", "Up to 2", "Up to 3", "Up to 5"])
    }
}

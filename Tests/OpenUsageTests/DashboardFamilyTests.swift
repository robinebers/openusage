import XCTest
@testable import OpenUsage

final class DashboardFamilyTests: XCTestCase {
    func testEveryMetricWithDataIsALineAndAccountsShareTheirProviderCard() {
        func provider(_ id: String) -> Provider {
            Provider(id: id, kind: .claude, accountLabel: id)
        }
        func data(_ title: String, hasData: Bool = true) -> WidgetData {
            var data = WidgetData(title: title, kind: .percent, used: 10, limit: 100)
            data.hasData = hasData
            return data
        }
        let samples = ["session": data("Session"), "fable": data("Fable"), "weekly": data("Weekly", hasData: false)]
        func descriptor(_ id: String) -> WidgetDescriptor {
            WidgetDescriptor(provider: Provider(id: "claude", kind: .claude), key: id, metricLabel: samples[id]!.title, sample: samples[id]!)
        }
        let groups = [
            ProviderMetrics(provider: provider("claude@1"), metrics: ["session", "fable", "weekly"].map(descriptor)),
            ProviderMetrics(provider: provider("claude@2"), metrics: [descriptor("fable")]),
        ]
        let families = DashboardFamily.make(groups: groups) { DashboardLine(descriptor: $0, data: $0.sample) }
        XCTAssertEqual(families.map(\.id), ["claude"])
        XCTAssertEqual(families[0].accounts.map { $0.lines.map(\.descriptor.key) }, [["session", "fable"], ["fable"]])
    }

    func testEachCaptionNamesItsAccountAndTheImageLeavesEmailsOut() {
        func family(_ accounts: [Provider]) -> DashboardFamily {
            DashboardFamily(id: "codex", provider: accounts[0], accounts: accounts.map { DashboardAccount(provider: $0, lines: []) })
        }
        func codex(_ label: String?) -> Provider {
            Provider(id: "codex@\(label ?? "plain")", kind: .codex, accountLabel: label)
        }
        XCTAssertEqual(family([codex("Sunstory")]).accounts.map(\.name), ["Sunstory"])
        XCTAssertEqual(family([codex("Sunstory"), codex("sam@hey.com"), codex("Codex"), codex(nil)]).accounts.map(\.name),
                       ["Sunstory", "sam@hey.com", "Codex", "ChatGPT"])
        XCTAssertEqual(family([codex("sam@hey.com")]).hidingEmails.accounts.map(\.name), ["ChatGPT"])
        XCTAssertEqual(family([codex("Sunstory"), codex("sam@hey.com")]).hidingEmails.accounts.map(\.name), ["Sunstory", "ChatGPT"])
    }

    func testTheLimitResetsRowShowsOnlyWhileAResetIsAvailable() {
        func resets(_ count: Double) -> WidgetData {
            var data = WidgetData(title: "Rate Limit Resets", kind: .count, used: count, limit: nil)
            data.values = [MetricValue(number: count, kind: .count, label: "available")]
            data.showsResetExpiries = true
            data.hidesAtZero = true
            return data
        }
        let weekly = WidgetData(title: "Weekly", kind: .percent, used: 10, limit: 100)
        func account(resetCount: Double) -> DashboardAccount {
            let samples = ["resets": resets(resetCount), "weekly": weekly]
            let group = ProviderMetrics(
                provider: Provider(id: "codex@1", kind: .codex),
                metrics: ["resets", "weekly"].map { WidgetDescriptor(provider: Provider(id: "codex", kind: .codex), key: $0, metricLabel: samples[$0]!.title, sample: samples[$0]!) }
            )
            return DashboardFamily.make(groups: [group]) { DashboardLine(descriptor: $0, data: $0.sample) }[0].accounts[0]
        }
        XCTAssertEqual(account(resetCount: 2).lines.map(\.descriptor.key), ["resets", "weekly"])
        XCTAssertEqual(account(resetCount: 0).lines.map(\.descriptor.key), ["weekly"])
    }

    @MainActor
    func testChatGPTExtraUsageRowShowsOnTheCardAndInTheMenuBarOnlyWhileCreditsAreLeft() {
        let account = Account(kind: .codex, label: "Work")
        let descriptors = AccountProviderRuntime.widgetDescriptors(for: account).filter { ["weekly", "credits"].contains($0.key) }
        let group = ProviderMetrics(provider: Provider(id: "codex@1", kind: .codex), metrics: descriptors)
        func shown(creditsRemaining: Double) -> (card: [String], menuBar: [String]) {
            func data(_ descriptor: WidgetDescriptor) -> WidgetData {
                var data = descriptor.sample
                if descriptor.key == "credits" { data.values = CodexUsageMapper.creditValues(remaining: creditsRemaining) }
                return data
            }
            let card = DashboardFamily.make(groups: [group]) { DashboardLine(descriptor: $0, data: data($0)) }
            let menuBar = MenuBarContentBuilder.build(groups: [group], data: data)
            return (card[0].accounts[0].lines.map(\.descriptor.key), menuBar.groups.flatMap(\.metrics).map(\.label))
        }
        XCTAssertEqual(shown(creditsRemaining: 25).card, ["weekly", "credits"])
        XCTAssertEqual(shown(creditsRemaining: 1).card, ["weekly", "credits"])
        XCTAssertEqual(shown(creditsRemaining: 1).menuBar, ["Weekly", "Credits"])
        XCTAssertEqual(shown(creditsRemaining: 0).card, ["weekly"])
        XCTAssertEqual(shown(creditsRemaining: 0).menuBar, ["Weekly"])
    }
}

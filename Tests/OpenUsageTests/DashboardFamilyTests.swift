import XCTest
@testable import OpenUsage

final class DashboardFamilyTests: XCTestCase {
    func testEveryMetricWithDataIsALineAndAccountsShareTheirProviderCard() {
        func provider(_ id: String) -> Provider {
            Provider(id: id, displayName: "Claude", icon: "claude", accountLabel: id)
        }
        func data(_ title: String, hasData: Bool = true) -> WidgetData {
            var data = WidgetData(title: title, kind: .percent, used: 10, limit: 100)
            data.hasData = hasData
            return data
        }
        let samples = ["session": data("Session"), "fable": data("Fable"), "weekly": data("Weekly", hasData: false)]
        func descriptor(_ id: String) -> WidgetDescriptor {
            WidgetDescriptor(id: id, providerID: "claude", metricLabel: samples[id]!.title, sample: samples[id]!)
        }
        let groups = [
            ProviderMetrics(provider: provider("claude@1"), metrics: ["session", "fable", "weekly"].map(descriptor)),
            ProviderMetrics(provider: provider("claude@2"), metrics: [descriptor("fable")]),
        ]
        let families = DashboardFamily.make(groups: groups) { DashboardLine(descriptor: $0, data: $0.sample) }
        XCTAssertEqual(families.map(\.id), ["claude"])
        XCTAssertEqual(families[0].accounts.map { $0.lines.map(\.id) }, [["session", "fable"], ["fable"]])
    }

    func testEachCaptionNamesItsAccountAndTheImageLeavesEmailsOut() {
        func family(_ accounts: [Provider]) -> DashboardFamily {
            DashboardFamily(id: "codex", provider: accounts[0], accounts: accounts.map { DashboardAccount(provider: $0, lines: []) })
        }
        func codex(_ label: String?) -> Provider {
            Provider(id: "codex@\(label ?? "plain")", displayName: "Codex", icon: "codex", accountLabel: label)
        }
        // A caption names its account by its name, by its email when it has no name of its own, and by
        // the provider's name when it has none at all; one account or several alike.
        XCTAssertEqual(family([codex("Sunstory")]).accounts.map(\.name), ["Sunstory"])
        XCTAssertEqual(family([codex("Sunstory"), codex("sam@hey.com"), codex("Codex"), codex(nil)]).accounts.map(\.name),
                       ["Sunstory", "sam@hey.com", "Codex", "Codex"])
        // The copied image keeps a custom name and drops an email.
        XCTAssertEqual(family([codex("sam@hey.com")]).hidingEmails.accounts.map(\.name), ["Codex"])
        XCTAssertEqual(family([codex("Sunstory"), codex("sam@hey.com")]).hidingEmails.accounts.map(\.name), ["Sunstory", "Codex"])
    }

    func testTheLimitResetsRowShowsOnlyWhileAResetIsAvailable() {
        func resets(_ count: Double) -> WidgetData {
            var data = WidgetData(title: "Rate Limit Resets", kind: .count, used: count, limit: nil)
            data.values = [MetricValue(number: count, kind: .count, label: "available")]
            data.showsResetExpiries = true
            return data
        }
        let weekly = WidgetData(title: "Weekly", kind: .percent, used: 10, limit: 100)
        func account(resetCount: Double) -> DashboardAccount {
            let samples = ["resets": resets(resetCount), "weekly": weekly]
            let group = ProviderMetrics(
                provider: Provider(id: "codex@1", displayName: "Codex", icon: "codex"),
                metrics: ["resets", "weekly"].map { WidgetDescriptor(id: $0, providerID: "codex", metricLabel: samples[$0]!.title, sample: samples[$0]!) }
            )
            return DashboardFamily.make(groups: [group]) { DashboardLine(descriptor: $0, data: $0.sample) }[0].accounts[0]
        }
        XCTAssertEqual(account(resetCount: 2).lines.map(\.id), ["resets", "weekly"])
        XCTAssertEqual(account(resetCount: 0).lines.map(\.id), ["weekly"])
    }
}

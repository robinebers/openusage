import XCTest
@testable import OpenUsage

/// Apart from the Limit Resets row's popover, right-click is the only way to act on the dashboard, and
/// its Share Screenshot the only way to copy a picture: a provider's header shares all its accounts, an
/// account's caption that account.
@MainActor
final class DashboardMenusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let claude = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let claudeLinks: [DashboardCommand?] = ProviderKind.claude.links.map { .open($0.url) }

    private func commands(_ sections: DashboardMenus.Sections) -> [[DashboardCommand?]] {
        sections.map { $0.map(\.command) }
    }

    private func account(resetExpiries: [Date]? = nil) -> DashboardAccount {
        var lines: [DashboardLine] = []
        if let resetExpiries {
            var data = WidgetData(title: "Limit Resets", kind: .count, used: 2, limit: nil)
            data.values = [MetricValue(number: 2, kind: .count, label: "available")]
            data.showsResetExpiries = true
            data.expiriesAt = resetExpiries
            lines = [DashboardLine(descriptor: WidgetDescriptor(provider: Provider(id: "claude", kind: .claude), key: "resets", metricLabel: data.title, sample: data), data: data)]
        }
        return DashboardAccount(provider: claude, lines: lines)
    }

    func testTheProviderMenuRefreshesManagesSharesEveryAccountAndOpensTheLinks() {
        let sole = DashboardMenus.provider(DashboardFamily(id: "claude", provider: claude, accounts: [account()]))
        XCTAssertEqual(commands(sole), [[.refresh(["claude@1"])], [.manageAccounts], [.shareScreenshot(["claude@1"])], claudeLinks],
                       "a one-account card's header has the provider's menu too")

        let other = Provider(id: "claude@2", kind: .claude, accountLabel: "AM 1")
        let family = DashboardFamily(id: "claude", provider: claude, accounts: [account(), DashboardAccount(provider: other, lines: [])])

        XCTAssertEqual(commands(DashboardMenus.provider(family)), [
            [.refresh(["claude@1", "claude@2"])],
            [.manageAccounts],
            [.shareScreenshot(["claude@1", "claude@2"])],
            claudeLinks,
        ])
    }

    func testThePlainAccountMenu() {
        let menu = DashboardMenus.account(account(), status: nil, hasHiddenMetrics: false)
        XCTAssertEqual(commands(menu), [
            [.refresh(["claude@1"]), .rename("claude@1"), .editAccount("claude@1")],
            [.shareScreenshot(["claude@1"])],
        ])
    }

    /// The menu says why the caption shows a warning and that metrics are hidden. Resets live in the
    /// Limit Resets row's popover, so the menu has no reset item even when the account has resets.
    func testTheAccountMenuExplainsItsStatusAndShowsHiddenMetrics() {
        let menu = DashboardMenus.account(
            account(resetExpiries: [now.addingTimeInterval(6 * 86_400)]),
            status: "Couldn't refresh. Check your connection.",
            hasHiddenMetrics: true
        )

        XCTAssertEqual(menu[0], [DashboardMenuItem(title: "Couldn't refresh. Check your connection.")], "the status is a disabled line")
        XCTAssertEqual(commands(menu), [
            [nil],
            [.refresh(["claude@1"]), .rename("claude@1"), .editAccount("claude@1")],
            [.shareScreenshot(["claude@1"])],
            [.showHiddenMetrics("claude@1")],
        ])
    }

    func testTheMetricMenuStarsAndHides() {
        let data = WidgetData(title: "Weekly", kind: .percent, used: 10, limit: 100)
        let descriptor = WidgetDescriptor(provider: claude, key: "weekly", metricLabel: "Weekly", sample: data)

        XCTAssertEqual(DashboardMenus.metric(descriptor, isStarred: false), [[
            DashboardMenuItem(title: "Star for Menu Bar", command: .toggleStar("claude@1.weekly")),
            DashboardMenuItem(title: "Hide", command: .hide("claude@1.weekly")),
        ]])
        XCTAssertEqual(DashboardMenus.metric(descriptor, isStarred: true)[0][0].title, "Unstar")
    }
}

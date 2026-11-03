import XCTest
@testable import OpenUsage

@MainActor
final class DashboardMenusTests: XCTestCase {
    private let claude = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let claudeLinks: [DashboardCommand?] = ProviderKind.claude.links.map { .open($0.url) }

    private func commands(_ sections: DashboardMenus.Sections) -> [[DashboardCommand?]] {
        sections.map { $0.map(\.command) }
    }

    private var account: DashboardAccount { DashboardAccount(provider: claude, lines: []) }

    func testTheProviderMenuRefreshesManagesSharesEveryAccountAndOpensTheLinks() {
        let sole = DashboardMenus.provider(DashboardFamily(id: "claude", provider: claude, accounts: [account]))
        XCTAssertEqual(commands(sole), [[.refresh(["claude@1"])], [.manageAccounts], [.shareScreenshot(["claude@1"])], claudeLinks],
                       "a one-account card's header has the provider's menu too")

        let other = Provider(id: "claude@2", kind: .claude, accountLabel: "AM 1")
        let family = DashboardFamily(id: "claude", provider: claude, accounts: [account, DashboardAccount(provider: other, lines: [])])

        XCTAssertEqual(commands(DashboardMenus.provider(family)), [
            [.refresh(["claude@1", "claude@2"])],
            [.manageAccounts],
            [.shareScreenshot(["claude@1", "claude@2"])],
            claudeLinks,
        ])
    }

    func testOpenRouterLinksIncludeCredits() {
        let openRouter = Provider(id: "openrouter@1", kind: .openrouter, accountLabel: "Personal")
        let family = DashboardFamily(id: "openrouter", provider: openRouter, accounts: [DashboardAccount(provider: openRouter, lines: [])])

        XCTAssertEqual(DashboardMenus.provider(family).last, [
            DashboardMenuItem(title: "Status Page", command: .open(URL(string: "https://status.openrouter.ai/")!)),
            DashboardMenuItem(title: "Usage Dashboard", command: .open(URL(string: "https://openrouter.ai/activity")!)),
            DashboardMenuItem(title: "Credits", command: .open(URL(string: "https://openrouter.ai/settings/credits")!)),
        ])
    }

    func testOllamaAndZaiLinksIncludeAPIKeys() {
        let ollama = Provider(id: "ollama@1", kind: .ollama, accountLabel: "Personal")
        let zai = Provider(id: "zai@1", kind: .zai, accountLabel: "Personal")

        XCTAssertEqual(DashboardMenus.provider(DashboardFamily(id: "ollama", provider: ollama, accounts: [DashboardAccount(provider: ollama, lines: [])])).last, [
            DashboardMenuItem(title: "Usage Dashboard", command: .open(URL(string: "https://ollama.com/settings")!)),
            DashboardMenuItem(title: "API Keys", command: .open(URL(string: "https://ollama.com/settings/keys")!)),
        ])
        XCTAssertEqual(DashboardMenus.provider(DashboardFamily(id: "zai", provider: zai, accounts: [DashboardAccount(provider: zai, lines: [])])).last, [
            DashboardMenuItem(title: "Usage Dashboard", command: .open(URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!)),
            DashboardMenuItem(title: "API Keys", command: .open(URL(string: "https://z.ai/manage-apikey/apikey-list")!)),
        ])
    }

    func testACopilotOrganizationRowOpensItsBillingAndTheCardKeepsThePersonalPage() {
        let organization = AccountProviderRuntime.provider(for: Account(kind: .copilot, label: "acme", organization: "acme"))
        let seat = AccountProviderRuntime.provider(for: Account(kind: .copilot, label: "Personal"))
        let family = DashboardFamily(id: "copilot", provider: organization, accounts: [
            DashboardAccount(provider: organization, lines: []), DashboardAccount(provider: seat, lines: []),
        ])

        XCTAssertEqual(DashboardMenus.account(family.accounts[0], status: nil).last, [
            DashboardMenuItem(title: "Organization Billing", command: .open(URL(string: "https://github.com/organizations/acme/settings/billing")!)),
        ])
        XCTAssertEqual(DashboardMenus.account(family.accounts[1], status: nil).last?.map(\.title), ["Share Screenshot"])
        XCTAssertEqual(DashboardMenus.provider(family).last, [
            DashboardMenuItem(title: "Status Page", command: .open(URL(string: "https://www.githubstatus.com/")!)),
            DashboardMenuItem(title: "Usage Dashboard", command: .open(URL(string: "https://github.com/settings/billing")!)),
        ])
    }

    func testAMetricIsPinnedOrUnpinnedWithThePinSymbols() {
        XCTAssertEqual(DashboardMenus.pin("claude@1.weekly", pinned: false),
                       DashboardMenuItem(title: "Pin", command: .setPinned("claude@1.weekly", true), systemImage: "pin"))
        XCTAssertEqual(DashboardMenus.pin("claude@1.weekly", pinned: true),
                       DashboardMenuItem(title: "Unpin", command: .setPinned("claude@1.weekly", false), systemImage: "pin.slash"))
    }

    func testTheAccountMenuKeepsItsActionsWhenShowingAStatus() {
        let menu = DashboardMenus.account(account, status: nil)
        XCTAssertEqual(commands(menu), [
            [.refresh(["claude@1"]), .rename("claude@1"), .editAccount("claude@1")],
            [.shareScreenshot(["claude@1"])],
        ])
        let message = "Couldn't refresh. Check your connection."
        XCTAssertEqual(DashboardMenus.account(account, status: message), [[DashboardMenuItem(title: message)]] + menu)
    }
}

import XCTest
@testable import OpenUsage

final class AccountInitialsTests: XCTestCase {
    func testTagIsTheFirstLetterOfTheFirstAndLastWord() {
        XCTAssertEqual(AccountInitials.tag(for: "Attention Machine 1"), "A1")
        XCTAssertEqual(AccountInitials.tag(for: "rob@sunstory.com"), "R")
        XCTAssertEqual(AccountInitials.tag(for: "Personal"), "P")
        XCTAssertEqual(AccountInitials.tag(for: "  side   project  "), "SP")
        XCTAssertEqual(AccountInitials.tag(for: ""), "")
    }

    @MainActor
    func testStripBadgesOnlyProvidersWithSeveralAccounts() {
        func account(_ id: String, _ label: String) -> DashboardAccount {
            let provider = Provider(id: id, kind: id.hasPrefix("codex") ? .codex : .claude, accountLabel: label)
            let sample = WidgetData(title: "Session", kind: .percent, used: 95, limit: 100)
            let descriptor = WidgetDescriptor(provider: provider, key: "session", metricLabel: "Session", sample: sample)
            return DashboardAccount(provider: provider, lines: [DashboardLine(descriptor: descriptor, data: sample)])
        }
        func strip(_ accounts: DashboardAccount...) -> MenuBarContent {
            MenuBarContentBuilder.build(board: PriorityBoard.make(accounts: accounts, now: Date()), limit: .upToFive)
        }
        let content = strip(
            account("claude@1", "Personal"), account("claude@2", "Attention Machine 1"),
            account("claude@3", "Attention Machine 2"), account("codex@1", "rob@sunstory.com")
        )
        XCTAssertEqual(content.items.map(\.badge), ["P", "A1", "A2", nil])

        XCTAssertEqual(strip(account("claude@1", "Work"), account("claude@2", "Work")).items.map(\.badge), ["W", "W"])
    }
}

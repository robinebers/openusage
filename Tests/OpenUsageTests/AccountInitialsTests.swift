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
        func group(_ id: String, _ label: String) -> ProviderMetrics {
            let provider = Provider(id: id, displayName: "P", icon: "claude", accountLabel: label)
            let sample = WidgetData(title: "Session", kind: .percent, used: 10, limit: 100)
            let descriptor = WidgetDescriptor(id: "\(id).session", providerID: id, metricLabel: "Session", sample: sample)
            return ProviderMetrics(provider: provider, metrics: [descriptor])
        }
        let content = MenuBarContentBuilder.build(
            groups: [
                group("claude@1", "Personal"), group("claude@2", "Attention Machine 1"),
                group("claude@3", "Attention Machine 2"), group("codex@1", "rob@sunstory.com"),
            ],
            data: { $0.sample }
        )
        XCTAssertEqual(content.groups.map(\.badge), ["P", "A1", "A2", nil])

        let alike = MenuBarContentBuilder.build(
            groups: [group("claude@1", "Work"), group("claude@2", "Work")],
            data: { $0.sample }
        )
        XCTAssertEqual(alike.groups.map(\.badge), ["W", "W"])
    }
}

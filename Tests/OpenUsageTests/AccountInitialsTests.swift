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

    func testEveryAccountOfAProviderWithSeveralCarriesItsInitials() {
        let registry = WidgetRegistry(providers: [
            Provider(id: "claude@1", kind: .claude, accountLabel: "Personal"),
            Provider(id: "claude@2", kind: .claude, accountLabel: "Attention Machine 1"),
            Provider(id: "codex@1", kind: .codex, accountLabel: "rob@sunstory.com"),
        ], descriptors: [])

        XCTAssertEqual(registry.providers.map(\.badge), ["P", "A1", nil])
        XCTAssertEqual(registry.provider(id: "claude@2")?.badge, "A1")
    }
}

import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class AccountChangeTests: XCTestCase {
    func testAccountChangesUpdateTheDashboardInPlace() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = await AppContainer.forTesting(accounts: accounts, defaults: defaults)
        let layout = container.layout
        let dataStore = container.dataStore
        XCTAssertTrue(layout.displayGroups.isEmpty)

        let codex = accounts.add(kind: .codex, label: "Work", credential: .apiKey("key"))
        try await waitUntil { layout.displayGroups.map(\.provider.id) == [codex.cardID] }
        XCTAssertEqual(layout.displayGroups.first?.provider.accountLabel, "Work")

        let claude = accounts.add(kind: .claude, label: "Home", credential: .apiKey("key"))
        try await waitUntil { layout.displayGroups.count == 2 }
        XCTAssertEqual(Set(layout.displayGroups.map(\.provider.id)), [codex.cardID, claude.cardID])

        accounts.rename(codex.id, to: "Personal")
        try await waitUntil {
            layout.displayGroups.first { $0.provider.id == codex.cardID }?.provider.accountLabel == "Personal"
        }

        accounts.remove(claude.id)
        try await waitUntil { layout.displayGroups.map(\.provider.id) == [codex.cardID] }

        XCTAssertTrue(container.layout === layout)
        XCTAssertTrue(container.dataStore === dataStore)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
}

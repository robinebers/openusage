import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class AccountChangeTests: XCTestCase {
    func testAccountChangesUpdateTheDashboardInPlace() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults)
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

    func testReplacingAKeySavesOnlyAKeyTheProviderAcceptsAndKeepsTheAccount() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let http = RoutingHTTPClient { request in
            guard request.headers["Authorization"] == "Bearer new-key" else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            let body = request.url.absoluteString == OpenRouterUsageClient.creditsURL
                ? #"{"data":{"total_credits":100,"total_usage":22.23}}"#
                : #"{"data":{"usage_daily":1.5,"usage_weekly":4,"usage_monthly":12}}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let personal = accounts.add(kind: .openrouter, label: "Personal", credential: .apiKey("old-key"))
        let work = accounts.add(kind: .openrouter, label: "Work", credential: .apiKey("work-key"))
        let dataStore = container.dataStore
        try await waitUntil { dataStore.errorMessage(for: personal.cardID) != nil && dataStore.errorMessage(for: work.cardID) != nil }
        container.layout.togglePin("\(personal.cardID).today")
        let stars = container.layout.pinnedMetricIDs
        XCTAssertTrue(stars.contains("\(personal.cardID).today"))

        do {
            try await container.replaceKey("refused-key", for: personal.cardID)
            XCTFail("a refused key was accepted")
        } catch {
            XCTAssertEqual(error.localizedDescription, "OpenRouter rejected the API key. Replace it on the account's page.")
        }
        XCTAssertEqual(try vault.load(personal.id), .apiKey("old-key"))

        do {
            try await container.replaceKey("work-key", for: personal.cardID)
            XCTFail("another account's key was accepted")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This account is already added as Work.")
        }
        XCTAssertEqual(try vault.load(personal.id), .apiKey("old-key"))
        try vault.delete(personal.id)

        try await container.replaceKey(" new-key ", for: personal.cardID)

        XCTAssertEqual(try vault.load(personal.id), .apiKey("new-key"))
        XCTAssertEqual(accounts.accounts.map(\.id), [personal.id, work.id])
        XCTAssertEqual(accounts.accounts.map(\.label), ["Personal", "Work"])
        XCTAssertEqual(container.layout.pinnedMetricIDs, stars)
        XCTAssertNil(dataStore.errorMessage(for: personal.cardID))
        XCTAssertNotNil(dataStore.snapshots[personal.cardID])
    }

    func testAReplacedKeyOutlastsARefreshStillReadingTheOldKey() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let oldRead = HeldResponse()
        let http = RoutingHTTPClient { request in
            guard request.headers["Authorization"] == "Bearer new-key" else {
                await oldRead.hold()
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            let body = request.url.absoluteString == OpenRouterUsageClient.creditsURL
                ? #"{"data":{"total_credits":100,"total_usage":22.23}}"#
                : #"{"data":{"usage_daily":1.5,"usage_weekly":4,"usage_monthly":12}}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let account = accounts.add(kind: .openrouter, label: "Personal", credential: .apiKey("old-key"))
        let dataStore = container.dataStore
        await oldRead.waitUntilHeld()
        XCTAssertEqual(dataStore.refreshingProviderIDs, [account.cardID])

        let replace = Task { try await container.replaceKey("new-key", for: account.cardID) }
        try await waitUntil { (try? vault.load(account.id)) == .apiKey("new-key") }
        await oldRead.release()
        try await replace.value
        try await waitUntil { dataStore.refreshingProviderIDs.isEmpty }

        XCTAssertEqual(try vault.load(account.id), .apiKey("new-key"))
        XCTAssertNil(dataStore.errorMessage(for: account.cardID))
        XCTAssertEqual(dataStore.snapshots[account.cardID]?.lines.map(\.label), ["Balance", "Today", "This Week", "This Month"])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
}

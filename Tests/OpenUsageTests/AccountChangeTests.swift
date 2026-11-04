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
            return Self.acceptedRead(request)
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let personal = accounts.add(kind: .openrouter, label: "Personal", credential: .apiKey("old-key"))
        let work = accounts.add(kind: .openrouter, label: "Work", credential: .apiKey("work-key"))
        let dataStore = container.dataStore
        try await waitUntil { dataStore.errorMessage(for: personal.cardID) != nil && dataStore.errorMessage(for: work.cardID) != nil }

        do {
            try await container.replaceKey("refused-key", for: personal.cardID)
            XCTFail("a refused key was accepted")
        } catch {
            XCTAssertEqual(error.localizedDescription, "OpenRouter rejected the API key.")
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
        XCTAssertNil(dataStore.errorMessage(for: personal.cardID))
        XCTAssertNotNil(dataStore.snapshots[personal.cardID])
    }

    func testAnInFlightRateLimitFromTheOldKeyDoesNotHoldTheNewKey() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let oldRead = HeldResponse()
        let http = RoutingHTTPClient { request in
            guard request.headers["Authorization"] == "Bearer new-key" else {
                await oldRead.hold()
                return HTTPResponse(statusCode: 429, headers: ["retry-after": "3600"], body: Data())
            }
            return Self.acceptedRead(request)
        }
        let account = accounts.add(kind: .openrouter, label: "Personal", credential: .apiKey("old-key"))
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let dataStore = container.dataStore
        let oldRefresh = Task { await dataStore.refresh(providerID: account.cardID, force: true) }
        await oldRead.waitUntilHeld()
        XCTAssertEqual(dataStore.refreshingProviderIDs, [account.cardID])

        let replace = Task { try await container.replaceKey("new-key", for: account.cardID) }
        try await waitUntil { (try? vault.load(account.id)) == .apiKey("new-key") }
        await oldRead.release()
        try await replace.value
        let oldOutcome = await oldRefresh.value
        XCTAssertEqual(oldOutcome, .skipped)
        XCTAssertTrue(dataStore.refreshingProviderIDs.isEmpty)

        XCTAssertEqual(try vault.load(account.id), .apiKey("new-key"))
        XCTAssertNil(dataStore.backoffs[account.cardID])
        XCTAssertEqual(dataStore.snapshots[account.cardID]?.lines.map(\.label), [
            "Key Limit", "Budget", "Free Requests", "Today", "This Week", "This Month"
        ])
    }

    func testAReplacedKeyIsReadAtOnceWhileTheOldKeyIsRateLimited() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let http = RoutingHTTPClient { request in
            guard request.headers["Authorization"] == "Bearer new-key" else {
                return HTTPResponse(statusCode: 429, headers: ["retry-after": "3600"], body: Data())
            }
            return Self.acceptedRead(request)
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let account = accounts.add(kind: .openrouter, label: "Personal", credential: .apiKey("old-key"))
        let dataStore = container.dataStore
        try await waitUntil { dataStore.backoffs[account.cardID]?.providerAsked == true }

        try await container.replaceKey("new-key", for: account.cardID)

        XCTAssertEqual(dataStore.snapshots[account.cardID]?.lines.map(\.label), [
            "Key Limit", "Budget", "Free Requests", "Today", "This Week", "This Month"
        ], "the old key's 429 held the new key")
    }

    func testReplacingAManagementKeyReplacesItsHistoricalWorkspaceUsage() async throws {
        let defaults = isolatedDefaults()
        let accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        // A completed day that would normally stay in the runtime's ledger until it ages out.
        let date = Date().addingTimeInterval(-7 * 86_400).formatted(.iso8601.year().month().day())
        let http = RoutingHTTPClient { request in
            guard request.url.path() == "/api/v1/activity" else { return OpenRouterFixtures.managementAccount(request) }
            let old = request.headers["Authorization"] == "Bearer old-key"
            let model = old ? "old-workspace-model" : "new-workspace-model"
            let body = #"{"data":[{"date":"\#(date)","model":"\#(model)","usage":\#(old ? 10 : 2),"requests":1,"prompt_tokens":3,"completion_tokens":2}]}"#
            return OpenRouterFixtures.response(200, body)
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let account = accounts.add(kind: .openrouter, label: "Work", credential: .apiKey("old-key"))
        let descriptor = try XCTUnwrap(container.layout.registry.descriptors(for: account.cardID).first { $0.key == "prior30" })
        try await waitUntil { container.dataStore.snapshots[account.cardID] != nil }
        XCTAssertEqual(container.dataStore.usageBreakdown(for: descriptor)?.models.map(\.name), ["old-workspace-model"])

        try await container.replaceKey("new-key", for: account.cardID)

        let breakdown = try XCTUnwrap(container.dataStore.usageBreakdown(for: descriptor))
        XCTAssertEqual(breakdown.models.map(\.name), ["new-workspace-model"])
        XCTAssertEqual(breakdown.totals[.spend], 2)
        let saved = try XCTUnwrap(ProviderSnapshotCache(userDefaults: defaults).load()[account.cardID])
        guard case .values(_, let amounts, _) = saved.line(label: descriptor.metricLabel) else {
            return XCTFail("the replacement's usage was not saved")
        }
        XCTAssertEqual(amounts.first?.number, 2)
    }

    func testAKeyAcceptedAfterTheAccountIsRemovedIsNotSaved() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let newKeyRead = HeldResponse()
        let http = RoutingHTTPClient { request in
            guard request.headers["Authorization"] == "Bearer new-key" else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            await newKeyRead.hold()
            return Self.acceptedRead(request)
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let account = accounts.add(kind: .openrouter, label: "Personal", credential: .apiKey("old-key"))

        let replace = Task { try await container.replaceKey("new-key", for: account.cardID) }
        await newKeyRead.waitUntilHeld()
        accounts.remove(account.id)
        await newKeyRead.release()
        try await replace.value

        XCTAssertNil(try vault.load(account.id), "the removed account's key came back")
        XCTAssertTrue(accounts.accounts.isEmpty)
    }

    func testAKeyAddedToAnotherAccountDuringValidationIsRejected() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let checking = HeldResponse()
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer shared" { await checking.hold() }
            return Self.acceptedRead(request)
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let first = accounts.add(kind: .openrouter, label: "Personal", credential: .apiKey("original"))
        let replacement = Task { try await container.replaceKey("shared", for: first.cardID) }
        await checking.waitUntilHeld()
        accounts.add(kind: .openrouter, label: "Work", credential: .apiKey("shared"))
        await checking.release()

        do {
            try await replacement.value
            XCTFail("The same key was saved to both accounts")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This account is already added as Work.")
        }
        XCTAssertEqual(try vault.load(first.id), .apiKey("original"))
    }

    func testAnEarlierEditCannotOverwriteAKeyReplacedWhileItWasValidating() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let checking = HeldResponse()
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer earlier" { await checking.hold() }
            return Self.acceptedRead(request)
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let account = accounts.add(kind: .openrouter, label: "Personal", credential: .apiKey("original"))
        let earlier = Task { try await container.replaceKey("earlier", for: account.cardID) }
        await checking.waitUntilHeld()
        try await container.replaceKey("later", for: account.cardID)
        await checking.release()

        do {
            try await earlier.value
            XCTFail("The superseded edit appeared to succeed")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This account’s sign-in changed while OpenUsage was checking it. Try again.")
        }
        XCTAssertEqual(try vault.load(account.id), .apiKey("later"))
    }

    private nonisolated static func acceptedRead(_ request: HTTPRequest) -> HTTPResponse {
        request.url.absoluteString == OpenRouterUsageClient.keyURL
            ? OpenRouterFixtures.response(200, OpenRouterFixtures.standardKey)
            : OpenRouterFixtures.response(403, OpenRouterFixtures.forbidden)
    }
}

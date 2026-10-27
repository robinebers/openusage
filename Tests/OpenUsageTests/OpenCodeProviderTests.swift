import Foundation
import XCTest
@testable import OpenUsage

/// OpenCode is named "OpenCode" with a "Go" plan tag, while every stored identifier keeps `opencode`.
@MainActor
final class OpenCodeProviderTests: XCTestCase {
    func testAccountSavedUnderTheOldRawValueStillLoads() throws {
        let name = "OpenUsage.Accounts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let saved = #"[{"id":"8AD3B217-0000-4000-8000-000000000000","kind":"opencode","label":"Work","addedAt":0}]"#
        defaults.set(Data(saved.utf8), forKey: AccountStore.storageKey)

        let account = try XCTUnwrap(AccountStore(defaults: defaults, vault: InMemoryCredentialVault()).accounts.first)

        XCTAssertEqual(account.kind, .opencodeGo)
        XCTAssertEqual(account.label, "Work")
        XCTAssertEqual(account.cardID, "opencode@8ad3b217")
        XCTAssertEqual(account.kind.displayName, "OpenCode")
    }

    /// Robin's dashboard read "OpenCode — OpenCode Go": the account was signed in when the provider was
    /// named "OpenCode Go", and the sign-in default stuck as its name. It takes the provider's name on
    /// load, so its caption reads "OpenCode" under the "OpenCode" header; a name of its own stays.
    func testAnAccountStillNamedByTheOldDefaultTakesTheNewOne() throws {
        let name = "OpenUsageLight.Accounts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let saved = #"[{"id":"8AD3B217-0000-4000-8000-000000000000","kind":"opencode","label":"OpenCode Go","addedAt":0},{"id":"8AD3B217-0000-4000-8000-000000000001","kind":"opencode","label":"Go Work","addedAt":1}]"#
        defaults.set(Data(saved.utf8), forKey: AccountStore.storageKey)

        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        XCTAssertEqual(store.accounts.map(\.label), ["OpenCode", "Go Work"])
        let reloaded = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        XCTAssertEqual(reloaded.accounts.map(\.label), ["OpenCode", "Go Work"], "the new name isn't saved")

        let provider = Provider(id: store.accounts[0].cardID, displayName: "OpenCode", icon: "opencode", accountLabel: store.accounts[0].label)
        XCTAssertEqual(DashboardAccount(provider: provider, lines: []).name, "OpenCode", "the caption would read \"\(provider.accountLabel ?? "")\"")
    }

    func testRefreshTagsTheAccountWithTheGoPlan() async throws {
        let account = Account(kind: .opencodeGo, label: "OpenCode")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("key"), for: account.id)
        let body = #"{"usage":{"rolling":{"percent":12,"resetsAt":"2026-07-12T13:30:00Z"},"weekly":{"percent":8,"resetsAt":"2026-07-13T00:00:00Z"},"monthly":{"percent":40,"resetsAt":"2026-08-04T11:18:32Z"}}}"#
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)) }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)

        let snapshot = await runtime.refresh()

        XCTAssertEqual(snapshot.displayName, "OpenCode")
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Monthly"])
        XCTAssertEqual(runtime.widgetDescriptors.map(\.id).first, "\(account.cardID).session")
    }
}

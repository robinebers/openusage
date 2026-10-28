import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class DuplicateLoginTests: XCTestCase {
    func testSigningInToAnAddedClaudeAccountAgainNamesTheExistingOne() async throws {
        let store = makeStore()
        store.add(kind: .claude, label: "Work", credential: Self.claude(identity: "acct/org"))

        let flow = flow(store) { Self.claude(identity: "acct/org") }
        flow.choose(.claude)
        try await waitUntil { flow.errorMessage != nil }

        XCTAssertEqual(flow.errorMessage, "This account is already added as Work.")
        XCTAssertEqual(store.accounts.map(\.label), ["Work"])
        XCTAssertFalse(flow.isFinished)
    }

    func testAnotherAccountOrOrganizationOfTheSameProviderIsAdded() async throws {
        let store = makeStore()
        store.add(kind: .claude, label: "Work", credential: Self.claude(identity: "acct/org"))

        let flow = flow(store) { Self.claude(identity: "acct/other-org") }
        flow.choose(.claude)
        try await waitUntil { flow.isFinished }
        XCTAssertEqual(store.accounts.count, 2)
    }

    func testTheSameAPIKeyIsNotAddedTwice() async throws {
        let store = makeStore()
        store.add(kind: .openrouter, label: "Personal", credential: .apiKey("sk-or-1"))

        let flow = AddAccountFlow(store: store)
        flow.choose(.openrouter)
        flow.apiKey = " sk-or-1 "
        flow.addKey()
        try await waitUntil { flow.errorMessage != nil }
        XCTAssertEqual(flow.errorMessage, "This account is already added as Personal.")
        XCTAssertEqual(store.accounts.count, 1)
    }

    func testASignInWithoutAnIdentityIsAlwaysAdded() async throws {
        let store = makeStore()
        store.add(kind: .claude, label: "Old", credential: .oauth(OAuthTokens(accessToken: "a")))

        let flow = flow(store) { .oauth(OAuthTokens(accessToken: "b")) }
        flow.choose(.claude)
        try await waitUntil { flow.isFinished }
        XCTAssertEqual(store.accounts.count, 2)
    }

    func testClaudeRefreshRecordsTheIdentityOfAnAccountAddedBeforeIdentities() async throws {
        let account = Account(kind: .claude, label: "Claude")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "access")), for: account.id)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/oauth/profile":
                HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"account":{"uuid":"acct"},"organization":{"uuid":"org"}}"#.utf8))
            default:
                HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":12}}"#.utf8))
            }
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        _ = await runtime.refreshHourlyReads(of: try await runtime.refresh().get())
        XCTAssertEqual(try vault.load(account.id)?.identity, "acct/org")
    }

    nonisolated private static func claude(identity: String) -> AccountCredential {
        .oauth(OAuthTokens(accessToken: UUID().uuidString, extras: [OAuthTokens.identityKey: identity]))
    }

    private func flow(_ store: AccountStore, credential: @escaping @Sendable () -> AccountCredential) -> AddAccountFlow {
        AddAccountFlow(store: store, openURL: { _ in }) { _ in IdentityLogin(credential: credential) }
    }

    private func makeStore() -> AccountStore {
        let defaults = isolatedDefaults()
        return AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the add-account flow")
    }
}

private struct IdentityLogin: ProviderLogin {
    let credential: @Sendable () -> AccountCredential

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        ("new@example.com", credential())
    }
}

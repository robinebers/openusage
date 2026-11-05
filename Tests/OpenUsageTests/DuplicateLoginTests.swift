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

    func testAnUnreadableStoredSignInDoesNotAllowADuplicateAccount() async throws {
        let vault = FailingVault()
        vault.loadError.value = CocoaError(.fileReadNoPermission)
        let store = AccountStore(defaults: isolatedDefaults(), vault: vault)
        store.add(kind: .claude, label: "Work", credential: Self.claude(identity: "acct/org"))

        let flow = flow(store) { Self.claude(identity: "acct/org") }
        flow.choose(.claude)
        try await waitUntil { flow.isFinished || flow.errorMessage != nil }

        XCTAssertEqual(flow.errorMessage, "OpenUsage couldn't check the saved sign-in for Work. Check Keychain access and try again.")
        XCTAssertEqual(store.accounts.map(\.label), ["Work"])
    }

    func testTheSameOrganizationIsNotAddedTwice() async throws {
        let store = makeStore()
        store.add(kind: .copilot, label: "acme", organization: "acme", credential: .apiKey("first"))

        let flow = flow(store) { .apiKey("second") }
        flow.choose(.copilot)
        flow.choose(.organizationToken)
        flow.organization = "ACME"
        flow.apiKey = "second"
        flow.addKey()
        try await waitUntil { flow.errorMessage != nil }

        XCTAssertEqual(flow.errorMessage, "This account is already added as acme.")
        XCTAssertEqual(store.accounts.map(\.label), ["acme"])
    }

    func testSigningInToAnAddedCursorAccountAgainNamesTheExistingOne() async throws {
        let token = "eyJhbGciOiJub25lIn0." + Data(#"{"sub":"auth0|user_abc"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".sig"
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"accessToken":"\#(token)","refreshToken":"r","authId":"auth0|user_abc"}"#.utf8))
        }
        let store = makeStore()
        let first = AddAccountFlow(store: store, openURL: { _ in }) { _, _, _, _ in CursorLogin(http: http) }
        first.choose(.cursor)
        try await waitUntil { first.isFinished }
        XCTAssertEqual(store.accounts.map(\.label), ["Cursor Account"])

        let again = AddAccountFlow(store: store, openURL: { _ in }) { _, _, _, _ in CursorLogin(http: http) }
        again.choose(.cursor)
        try await waitUntil { again.errorMessage != nil }

        XCTAssertEqual(again.errorMessage, "This account is already added as Cursor Account.")
        XCTAssertEqual(store.accounts.count, 1)
    }

    func testSigningInToAnAddedDevinAccountAgainNamesTheExistingOne() async throws {
        let store = makeStore()
        let first = try await signInToDevin(store, team: "devin-team$account-1")
        XCTAssertTrue(first.isFinished)

        let again = try await signInToDevin(store, team: "devin-team$account-1")

        XCTAssertEqual(again.errorMessage, "This account is already added as rob@example.com.")
        XCTAssertEqual(store.accounts.map(\.label), ["rob@example.com"])
    }

    func testTheSameDevinEmailInAnotherOrganizationIsAdded() async throws {
        let store = makeStore()
        _ = try await signInToDevin(store, team: "devin-team$account-1")

        let other = try await signInToDevin(store, team: "devin-team$account-2")

        XCTAssertTrue(other.isFinished)
        XCTAssertEqual(store.accounts.count, 2)
    }

    func testTheSameAPIKeyIsNotAddedTwice() async throws {
        let store = makeStore()
        store.add(kind: .openrouter, label: "Personal", credential: .apiKey("sk-or-1"))

        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: Data(OpenRouterFixtures.standardKey.utf8)) }
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { kind, _, _, _ in APIKeyLogin(kind: kind, http: http) }
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

    nonisolated private static func claude(identity: String) -> AccountCredential {
        .oauth(OAuthTokens(accessToken: UUID().uuidString, extras: [OAuthTokens.identityKey: identity]))
    }

    private func flow(_ store: AccountStore, credential: @escaping @Sendable () -> AccountCredential) -> AddAccountFlow {
        AddAccountFlow(store: store, openURL: { _ in }) { _, _, _, _ in IdentityLogin(credential: credential) }
    }

    /// Every sign-in is issued a new API key, so only the account's identity can tell it was added before.
    private func signInToDevin(_ store: AccountStore, team: String) async throws -> AddAccountFlow {
        let http = RoutingHTTPClient { request in
            let body = request.url.host() == "api.codeium.com"
                ? #"{"api_key":"devin-session-token$\#(UUID().uuidString)"}"#
                : #"{"userStatus":{"email":"rob@example.com","teamId":"\#(team)"}}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let flow = AddAccountFlow(store: store, openURL: { _ in }) { _, _, _, _ in DevinLogin(http: http) }
        flow.choose(.devin)
        try await waitUntil { flow.prompt != nil }
        flow.pastedCode = "one-time-token"
        flow.submitCode()
        try await waitUntil { flow.isFinished || flow.errorMessage != nil }
        return flow
    }

    private func makeStore() -> AccountStore {
        let defaults = isolatedDefaults()
        return AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
    }
}

private struct IdentityLogin: ProviderLogin {
    let credential: @Sendable () -> AccountCredential

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        ("new@example.com", credential())
    }
}

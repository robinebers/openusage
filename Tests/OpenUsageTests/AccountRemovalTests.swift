import Foundation
import XCTest
@testable import OpenUsage

/// Removing an account ends everything running on its behalf. The hazard is a token refresh suspended
/// at the network when the account is removed: its response must not save the rotated tokens back into
/// the Keychain or publish a snapshot for a card that no longer exists.
@MainActor
final class AccountRemovalTests: XCTestCase {
    func testRemovingAnAccountDiscardsItsInFlightTokenRefresh() async throws {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let account = accounts.add(
            kind: .claude,
            label: "Personal",
            credential: .oauth(OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast))
        )
        let network = HeldResponse()
        let http = RoutingHTTPClient { _ in
            await network.hold()
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)
            )
        }
        let container = await AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let dataStore = container.dataStore

        let refresh = Task { await dataStore.refresh(providerID: account.cardID, force: true) }
        await network.waitUntilHeld()
        XCTAssertEqual(dataStore.refreshingProviderIDs, [account.cardID])
        XCTAssertEqual(http.requests.map(\.url.absoluteString), ["https://platform.claude.com/v1/oauth/token"])

        accounts.remove(account.id)

        XCTAssertTrue(dataStore.refreshingProviderIDs.isEmpty, "removal cancels the refresh before remove returns")
        await network.release()
        let outcome = await refresh.value

        XCTAssertEqual(outcome, .skipped)
        XCTAssertNil(try vault.load(account.id), "the late token response must not recreate the credential")
        XCTAssertNil(dataStore.snapshots[account.cardID])
        XCTAssertNil(dataStore.errorMessage(for: account.cardID))
        XCTAssertTrue(dataStore.refreshingProviderIDs.isEmpty)
        XCTAssertTrue(ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: [account.cardID]).isEmpty)
        XCTAssertTrue(accounts.accounts.isEmpty)
        XCTAssertTrue(container.layout.displayGroups.isEmpty)
    }

    func testTheVaultOnlyUpdatesAnExistingCredential() throws {
        let vault = InMemoryCredentialVault()
        let id = UUID()

        XCTAssertThrowsError(try vault.update(.apiKey("late"), for: id)) { error in
            guard case CredentialVaultError.missingCredential = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(try vault.load(id))

        try vault.save(.apiKey("first"), for: id)
        try vault.update(.apiKey("second"), for: id)
        XCTAssertEqual(try vault.load(id), .apiKey("second"))
    }
}

/// A network response the test holds back and releases: `hold()` parks the caller until `release()`,
/// and `waitUntilHeld()` tells the test the request has arrived.
private actor HeldResponse {
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        arrived = true
        for waiter in arrivalWaiters { waiter.resume() }
        arrivalWaiters = []
        guard !released else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func waitUntilHeld() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        for continuation in held { continuation.resume() }
        held = []
    }
}

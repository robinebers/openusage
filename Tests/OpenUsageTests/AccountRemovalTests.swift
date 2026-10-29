import Foundation
import XCTest
@testable import OpenUsage

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
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
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
        XCTAssertNil(ProviderSnapshotCache(userDefaults: defaults).load()[account.cardID])
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

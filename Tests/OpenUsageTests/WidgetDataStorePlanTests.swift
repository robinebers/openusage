import XCTest
@testable import OpenUsage

@MainActor
final class WidgetDataStorePlanTests: XCTestCase {
    func testPlanMirrorsSnapshotAndHandlesMissingValues() async {
        let provider = Provider(id: "claude", kind: .claude)
        let cases: [(name: String, plan: String?)] = [("plan", "Max 20x"), ("no-plan", nil)]

        for item in cases {
            let runtime = StubRuntime(
                provider: provider,
                descriptors: [],
                snapshot: ProviderSnapshot(
                    providerID: provider.id, displayName: provider.displayName, plan: item.plan, lines: []
                )
            )
            let defaults = isolatedDefaults()
            let store = WidgetDataStore.forTesting([runtime], defaults: defaults)

            XCTAssertNil(store.plan(for: provider.id))
            await store.refreshAll()
            XCTAssertEqual(store.plan(for: provider.id), item.plan)
            XCTAssertNil(store.plan(for: "unknown"))
        }
    }

    func testAGrokTeamAccountShowsItsPlanAndTheNoticeWithNoRows() async throws {
        let account = Account(kind: .grok, label: "Team")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "token")), for: account.id)
        let settings = Data(#"{"subscription_tier_display":"SuperGrok Business"}"#.utf8)
        let noPersonalTeam = Data(#"{"error":"principal has no personal team"}"#.utf8)
        let billingStatus = TestSwitch(412)
        let http = RoutingHTTPClient { request in
            request.url == GrokUsageClient.settingsURL
                ? HTTPResponse(statusCode: 200, headers: [:], body: settings)
                : HTTPResponse(statusCode: billingStatus.value, headers: [:], body: noPersonalTeam)
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
        let id = runtime.provider.id

        await store.refreshAll()
        XCTAssertEqual(store.plan(for: id), "SuperGrok Business")
        XCTAssertEqual(store.notice(for: id), "Grok team accounts have no personal quota.")
        XCTAssertFalse(runtime.widgetDescriptors.contains { store.data(for: $0).hasData }, "a team account has no usage rows")

        billingStatus.value = 500
        await store.refreshAll(force: true)
        XCTAssertEqual(store.notice(for: id), "The provider request failed (HTTP 500).",
                       "a failed refresh shows its error, not the last snapshot's notice")
        XCTAssertEqual(store.plan(for: id), "SuperGrok Business")
    }
}

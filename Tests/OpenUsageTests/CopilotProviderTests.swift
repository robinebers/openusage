import XCTest
@testable import OpenUsage

@MainActor
final class CopilotProviderTests: XCTestCase {
    func testNotLoggedInWhenNoToken() async {
        let provider = CopilotProvider(
            authStore: CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain()),
            usageClient: CopilotUsageClient(
                http: FakeHTTPClient(
                    response: CopilotTestFixtures.ok(CopilotTestFixtures.paidBody())
                )
            )
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testTokenInvalidOn401() async {
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(
                http: FakeHTTPClient(
                    response: HTTPResponse(statusCode: 401, headers: [:], body: Data())
                )
            )
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testMapsLinesAndSendsTokenHeaderOnSuccess() async throws {
        let http = FakeHTTPClient(
            response: CopilotTestFixtures.ok(CopilotTestFixtures.paidBody())
        )
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.line(label: "Credits")?.label, "Credits")
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "token gho_editor")
    }

    func testTokenBasedBillingShowsPlanWithoutError() async {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "token_based_billing": true,
            "quota_snapshots": ["premium_interactions": ["entitlement": 0, "remaining": 0]]
        ]
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(
                http: FakeHTTPClient(response: CopilotTestFixtures.ok(body))
            )
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertTrue(snapshot.lines.isEmpty)
    }

    func testOrgManagedSeatShowsOrgBillingLines() async {
        let http = CopilotTestFixtures.routedClient([
            (
                "/copilot_internal/user",
                CopilotTestFixtures.ok(CopilotTestFixtures.businessPlaceholderBody())
            ),
            ("/user/orgs", CopilotTestFixtures.okJSON([["login": "acme"]])),
            (
                "/orgs/acme/settings/billing/usage/summary",
                CopilotTestFixtures.ok(CopilotTestFixtures.orgSummaryBody())
            )
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertEqual(
            CopilotTestFixtures.orgCount(snapshot.lines, "Org Credits") ?? -1,
            298.698546,
            accuracy: 0.0001
        )
        XCTAssertEqual(CopilotTestFixtures.orgDollars(snapshot.lines, "Org Spend"), 0)
        // The placeholder's overage_permitted: true must not leave a meaningless Extra Usage row.
        XCTAssertNil(snapshot.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testOrgBillingForbiddenKeepsPlanOnlyCard() async {
        // A plain org member (not owner/billing manager) gets 403 on org billing — the expected state,
        // which must keep today's plan-only card rather than erroring the provider.
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = CopilotTestFixtures.routedClient([
            (
                "/copilot_internal/user",
                CopilotTestFixtures.ok(CopilotTestFixtures.businessPlaceholderBody())
            ),
            ("/user/orgs", CopilotTestFixtures.okJSON([["login": "acme"]])),
            ("/orgs/acme/settings/billing/usage/summary", forbidden)
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertNil(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey))
    }

    func testUsesCachedOrgWithoutReprobing() async {
        let http = CopilotTestFixtures.routedClient([
            (
                "/copilot_internal/user",
                CopilotTestFixtures.ok(CopilotTestFixtures.businessPlaceholderBody())
            ),
            (
                "/orgs/acme/settings/billing/usage/summary",
                CopilotTestFixtures.ok(CopilotTestFixtures.orgSummaryBody())
            )
        ])
        let defaults = freshDefaults()
        defaults.set("acme", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(CopilotTestFixtures.orgCount(snapshot.lines, "Org Credits"))
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
    }

    func testEvictsStaleCachedOrgAndReprobes() async {
        // The cached org answers without Copilot usage (e.g. the user changed orgs) — it must be
        // forgotten and discovery re-run.
        let http = CopilotTestFixtures.routedClient([
            (
                "/copilot_internal/user",
                CopilotTestFixtures.ok(CopilotTestFixtures.businessPlaceholderBody())
            ),
            (
                "/orgs/oldorg/settings/billing/usage/summary",
                HTTPResponse(statusCode: 404, headers: [:], body: Data())
            ),
            ("/user/orgs", CopilotTestFixtures.okJSON([["login": "acme"]])),
            (
                "/orgs/acme/settings/billing/usage/summary",
                CopilotTestFixtures.ok(CopilotTestFixtures.orgSummaryBody())
            )
        ])
        let defaults = freshDefaults()
        defaults.set("oldorg", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(CopilotTestFixtures.orgCount(snapshot.lines, "Org Credits"))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testDiscoveryKeepsProbingPastAFailingOrg() async {
        // One org's billing endpoint having an outage (5xx) must not abort discovery — the next org's
        // usage should still be found and cached.
        let http = CopilotTestFixtures.routedClient([
            (
                "/copilot_internal/user",
                CopilotTestFixtures.ok(CopilotTestFixtures.businessPlaceholderBody())
            ),
            (
                "/user/orgs",
                CopilotTestFixtures.okJSON([["login": "brokenorg"], ["login": "acme"]])
            ),
            (
                "/orgs/brokenorg/settings/billing/usage/summary",
                HTTPResponse(statusCode: 503, headers: [:], body: Data())
            ),
            (
                "/orgs/acme/settings/billing/usage/summary",
                CopilotTestFixtures.ok(CopilotTestFixtures.orgSummaryBody())
            )
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(CopilotTestFixtures.orgCount(snapshot.lines, "Org Credits"))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testTransientBillingFailureKeepsCachedOrg() async {
        // A 5xx from the cached org's billing endpoint is a brief outage, not a stale org: the cache
        // must survive (no re-discovery), and the refresh degrades to the plan-only card.
        let http = CopilotTestFixtures.routedClient([
            (
                "/copilot_internal/user",
                CopilotTestFixtures.ok(CopilotTestFixtures.businessPlaceholderBody())
            ),
            (
                "/orgs/acme/settings/billing/usage/summary",
                HTTPResponse(statusCode: 503, headers: [:], body: Data())
            )
        ])
        let defaults = freshDefaults()
        defaults.set("acme", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
    }

    func testPersonalPaidAccountMakesNoOrgCalls() async {
        let http = CopilotTestFixtures.routedClient([
            (
                "/copilot_internal/user",
                CopilotTestFixtures.ok(CopilotTestFixtures.paidBody())
            )
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.count, 1)
    }

    private func makeOrgProvider(
        http: RoutingHTTPClient,
        defaults: UserDefaults
    ) -> CopilotProvider {
        CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: defaults
        )
    }

    private func freshDefaults() -> UserDefaults {
        let suiteName = "CopilotProviderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func editorTokenStore() -> CopilotAuthStore {
        CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#
            ]),
            keychain: FakeKeychain()
        )
    }
}

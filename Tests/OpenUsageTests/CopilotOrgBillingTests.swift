import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CopilotOrgBillingTests: XCTestCase {
    nonisolated private static let usageBody = #"""
    {"copilot_plan":"business","token_based_billing":true,
     "quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0,"unlimited":false,"credits_used":42}},
     "organization_login_list":["other-org","acme"],
     "organization_list":[{"login":"other-org","name":"Other"},{"login":"acme","name":"Acme"}]}
    """#
    nonisolated private static let orgBody = #"""
    {"timePeriod":{"year":2025},"organization":"GitHub","usageItems":[{"product":"Copilot","sku":"Copilot AI Credits",
     "model":"GPT-5","unitType":"credits","pricePerUnit":0.01,"grossQuantity":100,"grossAmount":1.0,"discountQuantity":0,
     "discountAmount":0.0,"netQuantity":100,"netAmount":1.0}]}
    """#
    nonisolated private static let noCopilotBody = #"{"usageItems":[{"product":"Actions","grossQuantity":500,"netAmount":4.0}]}"#
    private static let orgLines: [MetricLine] = [
        .values(label: "Org Credits", values: [MetricValue(number: 100, kind: .count, label: "credits")]),
        .values(label: "Org Spend", values: [MetricValue(number: 1, kind: .dollars)])
    ]
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testOrgUsageCountsCopilotCreditsAndSpendOnly() {
        XCTAssertEqual(CopilotOrgBillingMapper.usageLines(Self.ok(Self.orgBody)), Self.orgLines)
        XCTAssertEqual(CopilotOrgBillingMapper.usageLines(Self.ok(Self.noCopilotBody)), [
            .values(label: "Org Credits", values: [MetricValue(number: 0, kind: .count, label: "credits")]),
            .values(label: "Org Spend", values: [MetricValue(number: 0, kind: .dollars)])
        ], "an org with no Copilot usage yet shows zero")
    }

    func testAnInvalidOrgReportMapsToNothing() {
        for body in ["not json", "{}", #"{"usageItems":{"product":"Copilot"}}"#, #"{"usageItems":[{"product":"Copilot","grossQuantity":100}]}"#] {
            XCTAssertNil(CopilotOrgBillingMapper.usageLines(Self.ok(body)), body)
        }
    }

    func testOrgLoginsComeFromTheCopilotUsageBody() {
        XCTAssertEqual(CopilotOrgBillingMapper.orgLogins(Self.ok(Self.usageBody)), ["other-org", "acme"])
        XCTAssertEqual(CopilotOrgBillingMapper.orgLogins(Self.ok(#"{"copilot_plan":"pro"}"#)), [])
    }

    func testWithoutAnAdminTokenTheOrgIsNeverRead() async throws {
        let (snapshot, http) = try await refreshed(adminToken: nil)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Credits"])
        XCTAssertFalse(http.requests.contains { $0.url.path.hasSuffix("ai_credit/usage") })
    }

    func testAnAdminTokenAddsTheFirstOrgItCanReadAndKeepsItBetweenHourlyReads() async throws {
        let (snapshot, http) = try await refreshed(adminToken: "admin")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Credits", "Org Credits", "Org Spend"])
        XCTAssertEqual(Array(snapshot.lines.dropFirst()), Self.orgLines)
        let orgReads = http.requests.filter { $0.url.path.hasSuffix("ai_credit/usage") }
        XCTAssertEqual(orgReads.map(\.url), [
            CopilotUsageClient.orgCreditsURL(org: "other-org"), CopilotUsageClient.orgCreditsURL(org: "acme")
        ])
        XCTAssertEqual(orgReads.last?.url.absoluteString, "https://api.github.com/organizations/acme/settings/billing/ai_credit/usage")
        XCTAssertEqual(orgReads.last?.headers["Authorization"], "Bearer admin")
        XCTAssertEqual(orgReads.last?.headers["X-GitHub-Api-Version"], "2022-11-28")
    }

    func testARefusedOrgReadShowsNoOrgRowsAndNoError() async throws {
        let (snapshot, _) = try await refreshed(adminToken: "admin", orgStatus: 403)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Credits"])
    }

    func testSavingAnAdminTokenStoresOneThatReadsAnyOrgAndRemovingItDropsTheRows() async throws {
        let (container, vault, account) = makeContainer(usageBody: Self.usageBody)
        let signIn = OAuthTokens(accessToken: "gho-access", extras: [OAuthTokens.identityKey: "github:1"])

        do {
            try await container.saveAdminToken("refused", for: account.cardID)
            XCTFail("a refused admin token was saved")
        } catch {
            XCTAssertEqual(error.localizedDescription, "GitHub rejected the token.")
        }
        XCTAssertEqual(try vault.load(account.id), .oauth(signIn))
        let refusedTokenStored = await container.hasAdminToken(for: account.cardID)
        XCTAssertFalse(refusedTokenStored)

        try await container.saveAdminToken(" admin ", for: account.cardID)

        var withToken = signIn
        withToken.extras[OAuthTokens.adminTokenKey] = "admin"
        XCTAssertEqual(try vault.load(account.id), .oauth(withToken))
        let tokenStored = await container.hasAdminToken(for: account.cardID)
        XCTAssertTrue(tokenStored)
        XCTAssertEqual(container.dataStore.snapshots[account.cardID]?.lines.dropFirst().map { $0 }, Self.orgLines, "the rows come from acme, the org the token reads")

        try await container.saveAdminToken(nil, for: account.cardID)

        XCTAssertEqual(try vault.load(account.id), .oauth(signIn))
        XCTAssertEqual(container.dataStore.snapshots[account.cardID]?.lines.map(\.label), ["Credits"])
    }

    func testAnAccountWithNoOrganizationIsToldSo() async throws {
        let (container, vault, account) = makeContainer(usageBody: #"{"copilot_plan":"pro","token_based_billing":true}"#)
        do {
            try await container.saveAdminToken("admin", for: account.cardID)
            XCTFail("an admin token was saved for an account with no organization")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Copilot lists no organization for this account, so there is no org billing to read.")
        }
        XCTAssertEqual(try vault.load(account.id), .oauth(OAuthTokens(accessToken: "gho-access", extras: [OAuthTokens.identityKey: "github:1"])))
    }

    func testATokenWhoseReportDoesNotParseIsNotSaved() async throws {
        let (container, vault, account) = makeContainer(usageBody: Self.usageBody, orgBody: "<html>")
        do {
            try await container.saveAdminToken("admin", for: account.cardID)
            XCTFail("a token was saved on an unreadable report")
        } catch {
            XCTAssertEqual(error.localizedDescription, "GitHub rejected the token.")
        }
        XCTAssertEqual(try vault.load(account.id), .oauth(OAuthTokens(accessToken: "gho-access", extras: [OAuthTokens.identityKey: "github:1"])))
    }

    private func refreshed(adminToken: String?, orgStatus: Int = 200) async throws -> (ProviderSnapshot, RoutingHTTPClient) {
        let account = Account(kind: .copilot, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "gho-access", extras: adminToken.map { [OAuthTokens.adminTokenKey: $0] } ?? [:])), for: account.id)
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CopilotUsageClient.orgCreditsURL(org: "acme"): Self.response(orgStatus, Self.orgBody)
            case CopilotUsageClient.orgCreditsURL(org: "other-org"): Self.response(403, "{}")
            default: Self.ok(Self.usageBody)
            }
        }
        let clock = TestClock(start)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        let first = try await runtime.refresh().get()
        let reads = http.requests.count
        clock.set(start.addingTimeInterval(RefreshSetting.interval))
        let second = try await runtime.refresh().get()
        XCTAssertEqual(second.lines, first.lines, "the next pass keeps the hourly org rows")
        XCTAssertEqual(http.requests.count, reads + 1, "the next pass reads only the account's own usage")
        return (second, http)
    }

    private func makeContainer(usageBody: String, orgBody: String = orgBody) -> (AppContainer, InMemoryCredentialVault, Account) {
        let defaults = isolatedDefaults()
        let vault = InMemoryCredentialVault()
        let accounts = AccountStore(defaults: defaults, vault: vault)
        let http = RoutingHTTPClient { request in
            guard request.url.path.hasSuffix("ai_credit/usage") else { return Self.ok(usageBody) }
            let readable = request.url == CopilotUsageClient.orgCreditsURL(org: "acme") && request.headers["Authorization"] == "Bearer admin"
            return readable ? Self.ok(orgBody) : Self.response(403, "{}")
        }
        let container = AppContainer.forTesting(accounts: accounts, defaults: defaults, http: http)
        let account = accounts.add(kind: .copilot, label: "Work", credential: .oauth(OAuthTokens(
            accessToken: "gho-access", extras: [OAuthTokens.identityKey: "github:1"]
        )))
        return (container, vault, account)
    }

    nonisolated private static func ok(_ body: String) -> HTTPResponse {
        response(200, body)
    }

    nonisolated private static func response(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
    }
}

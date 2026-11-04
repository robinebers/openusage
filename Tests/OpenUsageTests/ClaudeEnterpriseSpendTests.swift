import XCTest
@testable import OpenUsage

/// #1260: an Enterprise organization is billed by what it spends, so its Extra Usage row reads Spend.
@MainActor
final class ClaudeEnterpriseSpendTests: XCTestCase {
    func testAnEnterpriseOrganizationsExtraUsageReadsSpendOnceItsPlanIsRead() async throws {
        let enterprise = try await extraUsageTitles(organizationType: "claude_enterprise")
        XCTAssertEqual(enterprise, ["Extra Usage", "Spend", "Spend"], "it changes in the slot that reads the plan and stays")

        let max = try await extraUsageTitles(organizationType: "claude_max")
        XCTAssertEqual(max, ["Extra Usage", "Extra Usage", "Extra Usage"])
    }

    /// The row's title after the first usage read, after the slot that reads the plan, and after the next usage read.
    private func extraUsageTitles(organizationType: String) async throws -> [String?] {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let http = RoutingHTTPClient { request in
            let body = request.url.path == "/api/oauth/profile"
                ? #"{"account":{"uuid":"acct"},"organization":{"uuid":"org","organization_type":"\#(organizationType)"}}"#
                : #"{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":true,"monthly_limit":120000,"used_credits":41800}}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let account = Account(kind: .claude, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "token", refreshToken: "refresh")), for: account.id)
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now })
        func title() -> String? {
            store.accounts(in: [ProviderMetrics(provider: runtime.provider, metrics: runtime.widgetDescriptors)])
                .flatMap(\.lines).first { $0.descriptor.key == "extra" }?.data.title
        }

        await store.refreshAll()
        let first = title()
        clock.set(clock.now.addingTimeInterval(RefreshSetting.interval / 2))
        await store.refreshHourlyReads()
        let slot = title()
        clock.set(clock.now.addingTimeInterval(RefreshSetting.interval))
        await store.refreshAll()
        return [first, slot, title()]
    }
}

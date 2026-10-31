import XCTest
@testable import OpenUsage

/// `/api/v1/key`, `/api/v1/credits`, and `/api/v1/keys` shaped as OpenRouter's API reference documents them.
enum OpenRouterFixtures {
    static let managementKey = #"""
    {"data":{"label":"sk-or-v1-0e6...1c96","limit":null,"limit_remaining":null,"limit_reset":null,
    "include_byok_in_limit":false,"usage":0,"usage_daily":0,"usage_weekly":0,"usage_monthly":0,
    "byok_usage":0,"byok_usage_daily":0,"byok_usage_weekly":0,"byok_usage_monthly":0,
    "is_free_tier":false,"is_management_key":true,"is_provisioning_key":true}}
    """#
    static let standardKey = #"""
    {"data":{"label":"sk-or-v1-au7...890","limit":100,"limit_remaining":74.5,"limit_reset":"monthly",
    "include_byok_in_limit":false,"usage":25.5,"usage_daily":1.5,"usage_weekly":4,"usage_monthly":12,
    "byok_usage":17.38,"byok_usage_daily":17.38,"byok_usage_weekly":17.38,"byok_usage_monthly":17.38,
    "is_free_tier":false,"is_management_key":false,"is_provisioning_key":false,
    "effective_budget":{"scope":"member","guardrail_id":"0df9e665-d932-5740-b2c7-b52af166bc11","budget_id":null,"limit_usd":50,
    "spend_usd":32.5,"remaining_usd":17.5,"reset_interval":"weekly","resets_at":"2026-11-02T00:00:00.000Z","include_byok":false},
    "free_model_daily_requests":{"used":12,"limit":50,"remaining":38}}}
    """#
    static let credits = #"{"data":{"total_credits":100,"total_usage":22.25}}"#
    static let forbidden = #"{"error":{"code":403,"message":"Forbidden"}}"#

    static func keysPage(_ count: Int, daily: Double, weekly: Double, monthly: Double) -> String {
        let key = """
        {"hash":"f01d52606dc8f0a8303a7b5cc3fa07109c2e346cec7c0a16b40de462992ce943","name":"Agent",
        "label":"sk-or-v1-0e6...1c96","disabled":false,"limit":null,"limit_remaining":null,"limit_reset":null,
        "include_byok_in_limit":false,"usage":\(monthly),"usage_daily":\(daily),"usage_weekly":\(weekly),
        "usage_monthly":\(monthly),"byok_usage":0,"byok_usage_daily":0,"byok_usage_weekly":0,"byok_usage_monthly":0,
        "created_at":"2025-08-24T10:30:00Z","updated_at":"2025-08-24T15:45:00Z","expires_at":null}
        """
        return #"{"data":["# + Array(repeating: key, count: count).joined(separator: ",") + "]}"
    }

    static func managementAccount(_ request: HTTPRequest) -> HTTPResponse {
        switch request.url.path() {
        case "/api/v1/key": return response(200, managementKey)
        case "/api/v1/credits": return response(200, credits)
        case "/api/v1/keys" where offset(request) == "0": return response(200, keysPage(100, daily: 0.25, weekly: 0.5, monthly: 1))
        case "/api/v1/keys" where offset(request) == "100": return response(200, keysPage(1, daily: 1.5, weekly: 4, monthly: 12))
        case "/api/v1/activity": return OpenRouterUsageHistoryTests.activity(request)
        default: return response(404)
        }
    }

    static func offset(_ request: HTTPRequest) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value
    }

    static func response(_ status: Int, _ body: String = "") -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
    }
}

@MainActor
final class OpenRouterProviderTests: XCTestCase {
    private static let now = ISO8601DateFormatter().date(from: "2026-10-29T11:00:00Z")!

    private func runtime(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) throws
        -> (AccountProviderRuntime, RoutingHTTPClient) {
        let account = Account(kind: .openrouter, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("key"), for: account.id)
        let http = RoutingHTTPClient(handler: handler)
        return (AccountProviderRuntime(account: account, vault: vault, http: http, now: { Self.now }), http)
    }

    private func shownRows(_ snapshot: ProviderSnapshot, _ runtime: AccountProviderRuntime) -> [String] {
        runtime.widgetDescriptors.filter { snapshot.line(label: $0.metricLabel) != nil }.map(\.key)
    }

    private func dollars(_ snapshot: ProviderSnapshot, _ label: String) -> Double? {
        guard case .values(_, let values, _) = snapshot.line(label: label) else { return nil }
        return values.first?.number
    }

    func testAManagementKeyShowsTheAccountsSpendSummedOverEveryPageOfKeys() async throws {
        let (runtime, http) = try runtime(OpenRouterFixtures.managementAccount)

        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(shownRows(snapshot, runtime), ["credits", "balance", "today", "yesterday", "week", "month", "prior30", "requests"])
        XCTAssertEqual(dollars(snapshot, "Today"), 26.5)
        XCTAssertEqual(dollars(snapshot, "This Week"), 54)
        XCTAssertEqual(dollars(snapshot, "This Month"), 112)
        XCTAssertEqual(dollars(snapshot, "Balance"), 77.75)
        XCTAssertEqual(snapshot.line(label: "Credits"), .progress(label: "Credits", used: 22.25, limit: 100, format: .dollars))
        XCTAssertEqual(snapshot.plan, "Pay-as-you-go")
        XCTAssertEqual(http.requests.map { $0.url.path() }, ["/api/v1/key", "/api/v1/credits", "/api/v1/keys", "/api/v1/keys", "/api/v1/activity"])
        for (request, offset) in zip(http.requests.dropFirst(2), ["0", "100"]) {
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(Set(query), [
                URLQueryItem(name: "include_disabled", value: "true"),
                URLQueryItem(name: "include_expired", value: "true"),
                URLQueryItem(name: "offset", value: offset)
            ])
        }
    }

    func testAWorkspaceScopedManagementKeyShowsItsWorkspacesSpendWithoutCredits() async throws {
        let (runtime, http) = try runtime { request in
            request.url.path() == "/api/v1/credits"
                ? OpenRouterFixtures.response(403, OpenRouterFixtures.forbidden)
                : OpenRouterFixtures.managementAccount(request)
        }

        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(shownRows(snapshot, runtime), ["today", "yesterday", "week", "month", "prior30", "requests"])
        XCTAssertEqual(dollars(snapshot, "Today"), 26.5)
        XCTAssertEqual(dollars(snapshot, "This Week"), 54)
        XCTAssertEqual(dollars(snapshot, "This Month"), 112)
        XCTAssertEqual(http.requests.map { $0.url.path() }, ["/api/v1/key", "/api/v1/credits", "/api/v1/keys", "/api/v1/keys", "/api/v1/activity"])
    }

    func testAStandardKeyShowsItsOwnSpendAndLimitWithoutAskingForTheAccountsCredits() async throws {
        let (runtime, http) = try runtime { request in
            request.url.path() == "/api/v1/key"
                ? OpenRouterFixtures.response(200, OpenRouterFixtures.standardKey)
                : OpenRouterFixtures.response(403, OpenRouterFixtures.forbidden)
        }

        let snapshot = try await runtime.refresh().get()

        XCTAssertEqual(shownRows(snapshot, runtime), ["today", "week", "month", "keyLimit", "budget", "freeRequests"])
        XCTAssertEqual(snapshot.line(label: "Today"), .values(label: "Today", values: [
            MetricValue(number: 1.5, kind: .dollars), MetricValue(number: 17.38, kind: .dollars, label: "BYOK")
        ]))
        XCTAssertEqual(dollars(snapshot, "This Week"), 4)
        XCTAssertEqual(dollars(snapshot, "This Month"), 12)
        XCTAssertEqual(snapshot.line(label: "Key Limit"), .progress(
            label: "Key Limit", used: 25.5, limit: 100, format: .dollars,
            resetsAt: ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"), periodDurationMs: 31 * MetricPeriod.dayMs
        ))
        XCTAssertEqual(snapshot.line(label: "Budget"), .progress(
            label: "Budget", used: 32.5, limit: 50, format: .dollars,
            resetsAt: ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z"), periodDurationMs: MetricPeriod.weekMs
        ))
        XCTAssertEqual(snapshot.line(label: "Free Requests"), .progress(
            label: "Free Requests", used: 12, limit: 50, format: .count(suffix: "requests"),
            resetsAt: ISO8601DateFormatter().date(from: "2026-10-30T00:00:00Z"), periodDurationMs: MetricPeriod.dayMs
        ))
        XCTAssertEqual(http.requests.map { $0.url.path() }, ["/api/v1/key"])
    }

    func testRestoredRowsKeepTheirOrderAndCreditsAndTodayAreStarredOnAFreshInstall() {
        let runtime = AccountProviderRuntime(account: Account(kind: .openrouter, label: "Work"), vault: InMemoryCredentialVault())
        let registry = WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors)

        let layout = LayoutStore(registry: registry, defaults: isolatedDefaults())

        XCTAssertEqual(runtime.widgetDescriptors.map(\.title), [
            "Credits", "Balance", "Today", "Yesterday", "This Week", "This Month", "Prior 30 Days", "Requests",
            "Key Limit", "Budget", "Free Requests"
        ])
        XCTAssertEqual(layout.pinnedMetricIDs, ["\(runtime.provider.id).credits", "\(runtime.provider.id).today"])
    }
}

import XCTest
@testable import OpenUsage

/// A Management key's card through the real runtime and store, with `/api/v1/activity` shaped as OpenRouter's
/// API reference documents it. Yesterday is 28 October 2026 UTC.
@MainActor
final class OpenRouterUsageHistoryTests: XCTestCase {
    nonisolated private static let now = ISO8601DateFormatter().date(from: "2026-10-29T11:00:00Z")!
    nonisolated private static let quietDay = "2026-10-20"

    nonisolated private static func activityRows(_ date: String) -> [String] {
        guard date != quietDay else { return [] }
        return [
            #"{"date":"\#(date)","model":"anthropic/claude-sonnet-4.5","model_permaslug":"anthropic/claude-sonnet-4.5","endpoint_id":"e1","provider_name":"Anthropic","usage":1.25,"byok_usage_inference":0.5,"requests":10,"prompt_tokens":1000,"completion_tokens":200,"reasoning_tokens":50,"cached_tokens":600}"#,
            #"{"date":"\#(date)","model":"openai/gpt-5","model_permaslug":"openai/gpt-5","endpoint_id":"e2","provider_name":"OpenAI","usage":0.25,"byok_usage_inference":0,"requests":2,"prompt_tokens":3000,"completion_tokens":100,"reasoning_tokens":0,"cached_tokens":0}"#
        ]
    }

    /// The last 30 finished UTC days, or the one `date` asks for.
    nonisolated static func activity(_ request: HTTPRequest) -> HTTPResponse {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dates = query.first { $0.name == "date" }?.value.map { [$0] }
            ?? (1...30).map { ISO8601DateFormatter.string(from: now.addingTimeInterval(Double(-$0) * 86_400), timeZone: .gmt, formatOptions: .withFullDate) }
        return OpenRouterFixtures.response(200, #"{"data":["# + dates.flatMap(activityRows).joined(separator: ",") + "]}")
    }

    private func makeAccount(activity: TestSwitch<Int?>, clock: TestClock) throws -> (WidgetDataStore, AccountProviderRuntime, RoutingHTTPClient) {
        let account = Account(kind: .openrouter, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("key"), for: account.id)
        let http = RoutingHTTPClient { request in
            guard request.url.path() == "/api/v1/activity" else { return OpenRouterFixtures.managementAccount(request) }
            return activity.value.map { OpenRouterFixtures.response($0) } ?? Self.activity(request)
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { clock.now })
        return (WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults(), now: { clock.now }), runtime, http)
    }

    private func rows(_ store: WidgetDataStore, _ runtime: AccountProviderRuntime) -> [String: String] {
        var rows: [String: String] = [:]
        for descriptor in runtime.widgetDescriptors where descriptor.historyRow != nil {
            let data = store.data(for: descriptor)
            if data.hasData { rows[descriptor.key] = data.unboundedDetail }
        }
        return rows
    }

    private func activityDates(_ http: RoutingHTTPClient) -> [String] {
        http.requests.filter { $0.url.path() == "/api/v1/activity" }.map {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "date" }?.value ?? "all"
        }
    }

    private func refresh(_ store: WidgetDataStore, _ runtime: AccountProviderRuntime) async {
        _ = await store.refresh(providerID: runtime.provider.id, force: true)
    }

    func testAManagementKeyShowsReportedSpendAndTheActivityOfThePrior30Days() async throws {
        let (store, runtime, http) = try makeAccount(activity: TestSwitch(nil), clock: TestClock(Self.now))

        await refresh(store, runtime)

        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        XCTAssertEqual(rows(store, runtime), [
            "today": "$26.50",
            "yesterday": "$1.50",
            "week": "$54",
            "month": "$112",
            "prior30": "$43.50"
        ])
        XCTAssertEqual(activityDates(http), ["all"])
    }

    func testEachWindowRowHasABreakdownOfWhatOpenRouterReported() async throws {
        let (store, runtime, _) = try makeAccount(activity: TestSwitch(nil), clock: TestClock(Self.now))
        let descriptor = { (key: String) in try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == key }) }

        await refresh(store, runtime)

        let prior = try XCTUnwrap(store.usageBreakdown(for: try descriptor("prior30")))
        XCTAssertEqual(prior.totals.values, [
            .spend: 43.5, .byokSpend: 14.5, .tokens: 124_700,
            .inputTokens: 98_600, .cacheReadTokens: 17_400, .outputTokens: 7_250, .reasoningTokens: 1_450
        ])
        XCTAssertTrue(prior.tokenPartsFillTotal)
        XCTAssertEqual(prior.models.map(\.name), ["anthropic/claude-sonnet-4.5", "openai/gpt-5"])
        XCTAssertEqual(prior.models.map(\.dollars), [36.25, 7.25])
        XCTAssertEqual(prior.models.map(\.tokens), [34_800, 89_900])
        XCTAssertEqual(prior.figures, ["$43.50", "124.7K tokens", "$14.50 BYOK"])
        let today = try XCTUnwrap(store.usageBreakdown(for: try descriptor("today")))
        XCTAssertEqual(today.totals.values, [.spend: 26.5, .byokSpend: 0])
        XCTAssertEqual(today.models, [])
        let week = try XCTUnwrap(store.usageBreakdown(for: try descriptor("week")))
        XCTAssertEqual(week.figures, ["$54", "12.9K tokens"], "the reported spend, with the tokens of Monday to yesterday")
        XCTAssertEqual(week.models.map(\.tokens), [3_600, 9_300])
        let month = try XCTUnwrap(store.usageBreakdown(for: try descriptor("month")))
        XCTAssertEqual(month.figures, ["$112", "116.1K tokens"], "a day with no activity adds no tokens")
    }

    func testActivityIsReadAgainHourlyAndANewUTCDayAtOnce() async throws {
        let clock = TestClock(Self.now)
        let (store, runtime, http) = try makeAccount(activity: TestSwitch(nil), clock: clock)
        await refresh(store, runtime)

        clock.set(Self.now.addingTimeInterval(300))
        await refresh(store, runtime)
        XCTAssertEqual(activityDates(http), ["all"], "a pass within the hour reads no activity")
        XCTAssertEqual(rows(store, runtime)["prior30"], "$43.50")

        clock.set(Self.now.addingTimeInterval(3_660))
        await refresh(store, runtime)
        XCTAssertEqual(activityDates(http), ["all", "2026-10-28"], "an hour later only yesterday is read again")

        await store.refresh(providerIDs: [runtime.provider.id], force: true)
        XCTAssertEqual(activityDates(http), ["all", "2026-10-28", "2026-10-28"], "Command-R reads yesterday again")

        clock.set(ISO8601DateFormatter().date(from: "2026-10-30T00:05:00Z")!)
        await refresh(store, runtime)
        XCTAssertEqual(activityDates(http), ["all", "2026-10-28", "2026-10-28", "2026-10-29"], "the new yesterday is read right after UTC midnight")
        XCTAssertEqual(rows(store, runtime)["prior30"], "$43.50")
    }

    func testAFailedActivityReadZeroesItsRangesKeepsTheCardAndWaitsAnHour() async throws {
        let activity = TestSwitch<Int?>(500)
        let clock = TestClock(Self.now)
        let (store, runtime, http) = try makeAccount(activity: activity, clock: clock)

        await refresh(store, runtime)
        activity.value = nil
        clock.set(Self.now.addingTimeInterval(300))
        await refresh(store, runtime)

        XCTAssertNil(store.errorMessage(for: runtime.provider.id))
        XCTAssertEqual(rows(store, runtime), ["today": "$26.50", "yesterday": "$0", "week": "$54", "month": "$112", "prior30": "$0"])
        XCTAssertEqual(activityDates(http), ["all"])

        clock.set(Self.now.addingTimeInterval(3_660))
        await refresh(store, runtime)
        XCTAssertEqual(activityDates(http), ["all", "all"])
        XCTAssertEqual(rows(store, runtime)["prior30"], "$43.50")
    }
}

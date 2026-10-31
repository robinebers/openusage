import XCTest
@testable import OpenUsage

final class OpenRouterUsageMapperTests: XCTestCase {
    private let thursday = ISO8601DateFormatter().date(from: "2026-10-29T11:00:00Z")!

    private func body(_ text: String) -> Data { Data(text.utf8) }

    private func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }

    private func keyLimit(_ fields: String) throws -> MetricLine? {
        let text = #"{"data":{"is_management_key":false,"usage_daily":0,"usage_weekly":0,"usage_monthly":0,"# + fields + "}}"
        return try OpenRouterUsageMapper.key(body(text), now: thursday).lines.first { $0.label == "Key Limit" }
    }

    func testAKeyResponseMissingWhatTheCardNeedsIsInvalid() {
        let malformed = [
            #"{"data":{"usage_daily":1.5,"usage_weekly":4,"usage_monthly":12}}"#,
            #"{"data":{"is_management_key":false,"usage_daily":1.5,"usage_weekly":4}}"#,
            #"{"data":{"is_management_key":false,"usage_daily":1.5,"usage_weekly":4,"usage_monthly":12,"limit":10,"limit_remaining":null}}"#,
            #"{"error":{"code":500,"message":"Internal Server Error"}}"#
        ]
        for text in malformed {
            XCTAssertThrowsError(try OpenRouterUsageMapper.key(body(text)), text) {
                XCTAssertEqual($0 as? ProviderError, .invalidResponse, text)
            }
        }
    }

    func testTheKeyLimitResetsAtMidnightUTCWithWeeksStartingMonday() throws {
        let cases: [(String, String?, Int?)] = [
            (#""daily""#, "2026-10-30T00:00:00Z", MetricPeriod.dayMs),
            (#""weekly""#, "2026-11-02T00:00:00Z", MetricPeriod.weekMs),
            (#""monthly""#, "2026-11-01T00:00:00Z", 31 * MetricPeriod.dayMs),
            ("null", nil, nil)
        ]
        for (reset, resetsAt, periodMs) in cases {
            XCTAssertEqual(try keyLimit(#""limit":10,"limit_remaining":7.5,"limit_reset":"# + reset), .progress(
                label: "Key Limit", used: 2.5, limit: 10, format: .dollars, resetsAt: resetsAt.flatMap(date), periodDurationMs: periodMs
            ), reset)
        }
        XCTAssertNil(try keyLimit(#""limit":null,"limit_remaining":null,"limit_reset":null"#))
    }

    func testCreditsShowAMeterOnceCreditsWereBoughtAndBalanceAlways() throws {
        XCTAssertEqual(try OpenRouterUsageMapper.creditsLines(body(OpenRouterFixtures.credits)), [
            .progress(label: "Credits", used: 22.25, limit: 100, format: .dollars),
            .values(label: "Balance", values: [MetricValue(number: 77.75, kind: .dollars)])
        ])
        XCTAssertEqual(try OpenRouterUsageMapper.creditsLines(body(#"{"data":{"total_credits":0,"total_usage":0}}"#)), [
            .values(label: "Balance", values: [MetricValue(number: 0, kind: .dollars)])
        ])
        XCTAssertThrowsError(try OpenRouterUsageMapper.creditsLines(body(#"{"data":{"total_credits":100}}"#)))
    }

    func testAKeysPageMustBeAListOfKeysWithTheirSpend() throws {
        let spend: [UsageWindow: UsageTotals] = [
            .today: UsageTotals(values: [.spend: 0.25, .byokSpend: 0]),
            .thisWeek: UsageTotals(values: [.spend: 0.5, .byokSpend: 0]),
            .thisMonth: UsageTotals(values: [.spend: 1, .byokSpend: 0])
        ]
        XCTAssertEqual(try OpenRouterUsageMapper.keysPage(body(OpenRouterFixtures.keysPage(2, daily: 0.25, weekly: 0.5, monthly: 1))),
                       [spend, spend])
        XCTAssertEqual(try OpenRouterUsageMapper.keysPage(body(#"{"data":[]}"#)), [])
        for text in [#"{"data":{"usage_daily":1}}"#, #"{"data":[{"hash":"abc","usage_daily":1,"usage_weekly":2}]}"#] {
            XCTAssertThrowsError(try OpenRouterUsageMapper.keysPage(body(text)), text)
        }
    }

    func testActivitySumsRowsPerUTCDayAndModelAndAMalformedRowRejectsTheRead() throws {
        let rows = #"""
        {"data":[{"date":"2026-10-28","model":"a","usage":1,"requests":2,"prompt_tokens":10,"completion_tokens":5},
        {"date":"2026-10-28","model":"a","usage":0.5,"requests":1,"prompt_tokens":4,"completion_tokens":1,"cached_tokens":2}]}
        """#
        let day = try XCTUnwrap(OpenRouterUsageMapper.activityDays(body(rows))?[try XCTUnwrap(date("2026-10-28T00:00:00Z"))])

        XCTAssertEqual(day.totals.values, [.spend: 1.5, .requests: 3, .tokens: 20, .inputTokens: 14, .outputTokens: 6],
                       "a measure one row leaves out is not reported for the day")
        XCTAssertEqual(day.byModel?["a"]?[.tokens], 20)
        for text in [
            #"{"data":{"date":"2026-10-28"}}"#,
            #"{"data":[{"date":"2026-10-28","model":"a","usage":1,"prompt_tokens":10,"completion_tokens":5}]}"#,
            #"{"data":[{"date":"2026-10-28","model":"a","usage":-1,"requests":1,"prompt_tokens":10,"completion_tokens":5}]}"#,
            #"{"data":[{"date":"yesterday","model":"a","usage":1,"requests":1,"prompt_tokens":10,"completion_tokens":5}]}"#
        ] {
            XCTAssertNil(OpenRouterUsageMapper.activityDays(body(text)), text)
        }
    }
}

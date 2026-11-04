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

    func testAKeyLimitWithoutAResetHasNoResetAndNoLimitHasNoRow() throws {
        XCTAssertEqual(try keyLimit(#""limit":10,"limit_remaining":7.5,"limit_reset":null"#), .progress(
            label: "Key Limit", used: 2.5, limit: 10, format: .dollars, resetsAt: nil, periodDurationMs: nil
        ))
        XCTAssertNil(try keyLimit(#""limit":null,"limit_remaining":null,"limit_reset":null"#))
    }

    /// `total_credits` is every credit ever bought, not a limit, so the credits show as a balance and never as a meter.
    func testCreditsShowOnlyTheBalance() throws {
        XCTAssertEqual(try OpenRouterUsageMapper.creditsLines(body(#"{"data":{"total_credits":10,"total_usage":12.5}}"#)), [
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
        {"date":"2026-10-28","model":"a","usage":0.5,"requests":1,"prompt_tokens":4,"completion_tokens":1,"cached_tokens":2,"reasoning_tokens":null}]}
        """#
        let day = try XCTUnwrap(OpenRouterUsageMapper.activityDays(body(rows))?[try XCTUnwrap(date("2026-10-28T00:00:00Z"))])

        XCTAssertEqual(day.totals.values, [.spend: 1.5, .tokens: 20, .inputTokens: 12, .outputTokens: 6, .cacheReadTokens: 2, .reasoningTokens: 0, .byokSpend: 0],
                       "a measure one row leaves out still counts from the rows that have it")
        XCTAssertEqual(day.byModel?["a"]?[.tokens], 20)
        for text in [
            #"{"data":{"date":"2026-10-28"}}"#,
            #"{"data":[{"date":"2026-10-28","model":"a","usage":1,"prompt_tokens":10}]}"#,
            #"{"data":[{"date":"2026-10-28","model":"a","usage":-1,"requests":1,"prompt_tokens":10,"completion_tokens":5}]}"#,
            #"{"data":[{"date":"yesterday","model":"a","usage":1,"requests":1,"prompt_tokens":10,"completion_tokens":5}]}"#
        ] {
            XCTAssertNil(OpenRouterUsageMapper.activityDays(body(text)), text)
        }
    }
}

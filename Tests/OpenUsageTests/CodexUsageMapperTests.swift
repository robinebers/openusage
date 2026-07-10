import XCTest
@testable import OpenUsage

final class CodexUsageMapperTests: XCTestCase {
    func testFreshSessionWindowPreservesReportedOnePercent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 1,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 18000,
              "reset_at": \(Int(now.timeIntervalSince1970) + 18000)
            }
          }
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)
        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 1)
    }

    func testFreshSessionWindowUsesDefaultPeriodWhenLimitWindowIsMissing() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAfterSeconds = CodexUsageMapper.sessionPeriodMs / 1000
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 1,
              "reset_after_seconds": \(resetAfterSeconds),
              "reset_at": \(Int(now.timeIntervalSince1970) + resetAfterSeconds)
            }
          }
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 1)
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, CodexUsageMapper.sessionPeriodMs)
    }

    func testMapsLimitWindowSecondsFromAPI() throws {
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": {
              "reset_after_seconds": 60,
              "used_percent": 1,
              "limit_window_seconds": 18000
            }
          }
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)
        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, 18_000_000)
    }

    func testMapsWindowsCreditsAndPlan() throws {
        let body = Data("""
        {
          "plan_type": "prolite",
          "rate_limit": {
            "primary_window": { "reset_after_seconds": 60, "used_percent": 10 },
            "secondary_window": { "reset_after_seconds": 120, "used_percent": 20 }
          },
          "credits": { "balance": "100" }
        }
        """.utf8)
        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "x-codex-primary-used-percent": "25",
                "x-codex-secondary-used-percent": "50"
            ],
            body: body
        )

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(mapped.plan, "Pro 5x")
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 10)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 20)
        // Credits lead with the dollar value (4¢/credit), then the raw count — no inverted fake cap.
        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertEqual(values(mapped.lines, "Credits"),
                       [MetricValue(number: 4.0, kind: .dollars), MetricValue(number: 100, kind: .count, label: "credits")])
        XCTAssertNotNil(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, CodexUsageMapper.sessionPeriodMs)
    }

    func testHeadersFillMissingWindows() throws {
        let body = Data("""
        {
          "rate_limit": {}
        }
        """.utf8)
        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "x-codex-primary-used-percent": "25",
                "x-codex-secondary-used-percent": "50"
            ],
            body: body
        )

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 25)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 50)
    }

    func testSessionWindowBeatsStaleHeader() throws {
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": { "reset_after_seconds": 60, "used_percent": 0 },
            "secondary_window": { "reset_after_seconds": 120, "used_percent": 7 }
          }
        }
        """.utf8)
        let response = HTTPResponse(
            statusCode: 200,
            headers: [
                "x-codex-primary-used-percent": "99",
                "x-codex-secondary-used-percent": "99"
            ],
            body: body
        )

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 0)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 7)
    }

    func testSurfacesSparkLinesFromAdditionalRateLimits() throws {
        // The usage body carries model-specific limits in `additional_rate_limits`; the Spark entry's
        // primary/secondary windows become the Spark (5-hour) and Spark Weekly meters. Regression for
        // issue #796 — the Swift edition dropped these when it didn't port the JS plugin's parsing.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowSec = Int(now.timeIntervalSince1970)
        let body = Data("""
        {
          "rate_limit": {
            "primary_window": { "used_percent": 5, "reset_after_seconds": 60 },
            "secondary_window": { "used_percent": 10, "reset_after_seconds": 120 }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "codex_bengalfox",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 25,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 3600,
                  "reset_at": \(nowSec + 3600)
                },
                "secondary_window": {
                  "used_percent": 40,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 86400,
                  "reset_at": \(nowSec + 86400)
                }
              }
            }
          ]
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertEqual(progress(mapped.lines, "Spark")?.used, 25)
        XCTAssertEqual(progress(mapped.lines, "Spark")?.periodDurationMs, 18_000_000)
        XCTAssertEqual(progress(mapped.lines, "Spark")?.resetsAt,
                       Date(timeIntervalSince1970: TimeInterval(nowSec + 3600)))
        XCTAssertEqual(progress(mapped.lines, "Spark Weekly")?.used, 40)
        XCTAssertEqual(progress(mapped.lines, "Spark Weekly")?.periodDurationMs, 604_800_000)
        // The core Session/Weekly windows are unaffected by the new parsing.
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 10)
    }

    func testMatchesSparkByMeteredFeatureWhenLimitNameLacksSpark() throws {
        // `limit_name` wording can shift; matching `metered_feature` too keeps the row resolving.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Data("""
        {
          "additional_rate_limits": [
            {
              "limit_name": "Research Preview",
              "metered_feature": "codex_spark_preview",
              "rate_limit": { "primary_window": { "used_percent": 12, "reset_after_seconds": 60 } }
            }
          ]
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertEqual(progress(mapped.lines, "Spark")?.used, 12)
    }

    func testIgnoresNonSparkAndMalformedAdditionalRateLimits() throws {
        // Non-Spark model limits have no descriptors, so they aren't surfaced; a null/non-dictionary
        // element is skipped without discarding its siblings; a Spark entry missing `rate_limit` yields
        // no lines. None of this should ever throw.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Data("""
        {
          "additional_rate_limits": [
            null,
            { "limit_name": "Some Other Model", "rate_limit": { "primary_window": { "used_percent": 50, "reset_after_seconds": 60 } } },
            { "limit_name": "GPT-5.3-Codex-Spark" }
          ]
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(response, now: now)

        XCTAssertNil(progress(mapped.lines, "Spark"))
        XCTAssertNil(progress(mapped.lines, "Spark Weekly"))
        XCTAssertNil(progress(mapped.lines, "Some Other Model"))
    }

    func testAppendsTokenUsageLines() {
        var lines: [MetricLine] = []
        let usage = DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-02-20", totalTokens: 150, costUSD: 0.75),
            DailyUsageEntry(date: "2026-02-01", totalTokens: 300, costUSD: 1.0)
        ])

        SpendTileMapper.appendTokenUsage(
            usage,
            to: &lines,
            now: makeDate("2026-02-20T16:00:00.000Z")
        )

        XCTAssertEqual(values(lines, "Today"),
                       [MetricValue(number: 0.75, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        // No usage yesterday → "No data" (no backing line), not a fabricated "$0.00 · 0 tokens".
        XCTAssertNil(values(lines, "Yesterday"))
        XCTAssertEqual(values(lines, "Last 30 Days"),
                       [MetricValue(number: 1.75, kind: .dollars, estimated: true),
                        MetricValue(number: 450, kind: .count, label: "tokens")])
    }

    func testZeroUsageLeavesTilesUnbacked() {
        // A period with no usage is "No data" — no tile is appended, never a fabricated "$0.00 · 0 tokens".
        // Fixed once in SpendTileMapper, so it holds for every provider that funnels through it. Here the
        // only reported day is a zero-token Yesterday; Today is absent, Yesterday is idle, and the 30-day
        // total is zero, so nothing is appended.
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [DailyUsageEntry(date: "2026-02-19", totalTokens: 0, costUSD: nil)]),
            to: &lines,
            now: makeDate("2026-02-20T16:00:00.000Z")
        )

        XCTAssertTrue(lines.isEmpty, "an all-zero window appends no spend tiles")
    }

    func testUnpricedTokensShowTokensWithoutAFabricatedZeroDollar() {
        // A day with real tokens the runner couldn't price omits the dollar — its cost is unknown, not
        // zero — so the row shows just the labeled token count rather than a misleading "$0.00 ·".
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [DailyUsageEntry(date: "2026-02-20", totalTokens: 1_200_000, costUSD: nil)]),
            to: &lines,
            now: makeDate("2026-02-20T16:00:00.000Z")
        )

        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 1_200_000, kind: .count, label: "tokens")])
    }

    // Regression: dollar amounts must group thousands (e.g. "$1,200.00") consistently with the
    // headline, which formats through `Formatters.currency`. Credit lines previously used a bare
    // `$%.2f` that dropped the separator.
    func testCreditValuesRenderGroupedThousands() {
        var data = WidgetData(title: "Extra Usage", icon: .providerMark("codex"), kind: .dollars, used: 0, limit: nil)
        data.values = CodexUsageMapper.creditValues(remaining: 30000)
        // The row abbreviates ("$1.2K · 30K credits"); the hover tooltip keeps every digit.
        XCTAssertEqual(data.unboundedDetail, "$1.2K · 30K credits")
        XCTAssertEqual(data.unboundedTooltip, "$1,200.00 · 30,000 credits")
    }

    func testShowsRateLimitResetsBeforeCredits() throws {
        let body = Data("""
        {
          "rate_limit_reset_credits": { "available_count": 1 },
          "credits": { "balance": 100 }
        }
        """.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(values(mapped.lines, "Rate Limit Resets"),
                       [MetricValue(number: 1, kind: .count, label: "available")])

        let resetIndex = mapped.lines.firstIndex { $0.label == "Rate Limit Resets" }
        let creditsIndex = mapped.lines.firstIndex { $0.label == "Credits" }
        XCTAssertNotNil(resetIndex)
        XCTAssertNotNil(creditsIndex)
        if let resetIndex, let creditsIndex {
            XCTAssertLessThan(resetIndex, creditsIndex)
        }
    }

    func testShowsZeroRateLimitResets() throws {
        let body = Data(#"{ "rate_limit_reset_credits": { "available_count": 0 } }"#.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(values(mapped.lines, "Rate Limit Resets"),
                       [MetricValue(number: 0, kind: .count, label: "available")])
    }

    func testDedicatedEndpointSuppliesCountAndSortedExpiries() throws {
        // The dedicated endpoint carries the per-credit expiry list the usage body lacks, so the count
        // comes from it and `expiriesAt` holds every still-available credit's expiry, sorted soonest
        // first. A non-"available" credit (the "consumed" one here) is excluded entirely.
        let usage = HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        let resetCredits = HTTPResponse(statusCode: 200, headers: [:], body: Data("""
        {
          "available_count": 2,
          "credits": [
            { "status": "available", "expires_at": "2026-02-20T19:00:00.000Z" },
            { "status": "available", "expires_at": "2026-02-20T17:30:00.000Z" },
            { "status": "consumed", "expires_at": "2026-02-20T16:10:00.000Z" }
          ]
        }
        """.utf8))

        let mapped = try CodexUsageMapper.mapUsageResponse(
            usage,
            resetCredits: resetCredits,
            now: OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        )

        guard case .values(_, let vals, _, let expiriesAt, _, _) = mapped.lines.first(where: { $0.label == "Rate Limit Resets" }) else {
            return XCTFail("expected a Rate Limit Resets values line")
        }
        XCTAssertEqual(vals, [MetricValue(number: 2, kind: .count, label: "available")])
        XCTAssertEqual(expiriesAt, [
            OpenUsageISO8601.date(from: "2026-02-20T17:30:00.000Z")!,
            OpenUsageISO8601.date(from: "2026-02-20T19:00:00.000Z")!
        ])
    }

    func testExpiriesPreservedWhenStatusOmitted() throws {
        // `status` is optional upstream — a credit with `expires_at` but no `status` must still count
        // toward the expiry list (otherwise the tooltip and the 24h warning vanish for that response
        // shape). An explicitly non-available credit is still dropped. (Regression for the Codex-flagged
        // "preserve expiries when status is omitted".)
        let usage = HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        let resetCredits = HTTPResponse(statusCode: 200, headers: [:], body: Data("""
        {
          "available_count": 2,
          "credits": [
            { "expires_at": "2026-02-20T19:00:00.000Z" },
            { "expires_at": "2026-02-20T17:30:00.000Z" },
            { "status": "consumed", "expires_at": "2026-02-20T16:10:00.000Z" }
          ]
        }
        """.utf8))

        let mapped = try CodexUsageMapper.mapUsageResponse(
            usage,
            resetCredits: resetCredits,
            now: OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        )

        guard case .values(_, _, _, let expiriesAt, _, _) = mapped.lines.first(where: { $0.label == "Rate Limit Resets" }) else {
            return XCTFail("expected a Rate Limit Resets values line")
        }
        // The two status-less credits are kept (sorted); the "consumed" one is dropped.
        XCTAssertEqual(expiriesAt, [
            OpenUsageISO8601.date(from: "2026-02-20T17:30:00.000Z")!,
            OpenUsageISO8601.date(from: "2026-02-20T19:00:00.000Z")!
        ])
    }

    func testFallsBackToUsageBodyCountWhenDedicatedFetchUnavailable() throws {
        // No dedicated response (the fetch failed): the count falls back to the usage body's embedded
        // object, and with no expiry list `expiriesAt` is empty.
        let usage = HTTPResponse(statusCode: 200, headers: [:],
                                 body: Data(#"{ "rate_limit_reset_credits": { "available_count": 3 } }"#.utf8))

        let mapped = try CodexUsageMapper.mapUsageResponse(
            usage,
            resetCredits: nil,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        guard case .values(_, let vals, _, let expiriesAt, _, _) = mapped.lines.first(where: { $0.label == "Rate Limit Resets" }) else {
            return XCTFail("expected a Rate Limit Resets values line")
        }
        XCTAssertEqual(vals, [MetricValue(number: 3, kind: .count, label: "available")])
        XCTAssertTrue(expiriesAt.isEmpty)
    }

    func testDedicatedNullCountFallsBackToUsageBodyCount() throws {
        // A 2xx dedicated payload whose `available_count` is JSON null (NSNull, which is non-nil) must NOT
        // be selected as the source — doing so would drop the whole row. It falls back to the usage body's
        // valid embedded count instead. (Regression for the bot-flagged NSNull nil-check.)
        let usage = HTTPResponse(statusCode: 200, headers: [:],
                                 body: Data(#"{ "rate_limit_reset_credits": { "available_count": 2 } }"#.utf8))
        let resetCredits = HTTPResponse(statusCode: 200, headers: [:],
                                        body: Data(#"{ "available_count": null }"#.utf8))

        let mapped = try CodexUsageMapper.mapUsageResponse(
            usage,
            resetCredits: resetCredits,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(values(mapped.lines, "Rate Limit Resets"),
                       [MetricValue(number: 2, kind: .count, label: "available")])
    }

    func testDedicatedNon2xxFallsBackToUsageBodyCount() throws {
        // A non-2xx dedicated response is ignored (treated as unavailable), so the count falls back to
        // the usage body — never a dropped row just because the extra endpoint erred.
        let usage = HTTPResponse(statusCode: 200, headers: [:],
                                 body: Data(#"{ "rate_limit_reset_credits": { "available_count": 1 } }"#.utf8))
        let resetCredits = HTTPResponse(statusCode: 500, headers: [:], body: Data("<html>oops</html>".utf8))

        let mapped = try CodexUsageMapper.mapUsageResponse(
            usage,
            resetCredits: resetCredits,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(values(mapped.lines, "Rate Limit Resets"),
                       [MetricValue(number: 1, kind: .count, label: "available")])
    }

    func testOmitsRateLimitResetsWhenCountMalformed() throws {
        let body = Data(#"{ "rate_limit_reset_credits": { "available_count": null } }"#.utf8)
        let response = HTTPResponse(statusCode: 200, headers: [:], body: body)

        let mapped = try CodexUsageMapper.mapUsageResponse(
            response,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNil(values(mapped.lines, "Rate Limit Resets"))
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }

    private func makeDate(_ value: String) -> Date {
        OpenUsageISO8601.date(from: value)!
    }
}

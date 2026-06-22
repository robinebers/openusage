import XCTest
@testable import OpenUsage

final class CodexAuthStoreTests: XCTestCase {
    func testParsesHexEncodedAuthPayload() {
        let raw = #"{"tokens":{"access_token":"token"},"last_refresh":"2026-01-01T00:00:00.000Z"}"#
        let hex = raw.utf8.map { String(format: "%02x", $0) }.joined()

        let auth = CodexAuthStore.parseAuth(hex)

        XCTAssertEqual(auth?.tokens?.accessToken, "token")
    }

    func testUsesCodexHomeAuthPathBeforeDefaultPaths() {
        let files = FakeFiles([
            "/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#
        ])
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
            files: files,
            keychain: FakeKeychain()
        )

        let (candidates, missing) = store.loadAuthCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(candidates.first?.auth.tokens?.accessToken, "token")
    }
}

final class CodexUsageMapperTests: XCTestCase {
    func testMapsHeadersCreditsAndPlan() throws {
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
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 25)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.used, 50)
        // Credits lead with the dollar value (4¢/credit), then the raw count — no inverted fake cap.
        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertEqual(values(mapped.lines, "Credits"),
                       [MetricValue(number: 4.0, kind: .dollars), MetricValue(number: 100, kind: .count, label: "credits")])
        XCTAssertNotNil(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, CodexUsageMapper.sessionPeriodMs)
    }

    func testAppendsTokenUsageLines() {
        var lines: [MetricLine] = []
        let usage = CcusageDailyUsage(daily: [
            CcusageDay(date: "2026-02-20", totalTokens: 150, costUSD: 0.75),
            CcusageDay(date: "2026-02-01", totalTokens: 300, costUSD: 1.0)
        ])

        SpendTileMapper.appendTokenUsage(
            usage,
            to: &lines,
            now: makeDate("2026-02-20T16:00:00.000Z")
        )

        XCTAssertEqual(values(lines, "Today"),
                       [MetricValue(number: 0.75, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        // No usage yesterday is a real, measured zero → "$0.00 · 0 tokens", not "0" and not "No data".
        XCTAssertEqual(values(lines, "Yesterday"),
                       [MetricValue(number: 0, kind: .dollars, estimated: true),
                        MetricValue(number: 0, kind: .count, label: "tokens")])
        XCTAssertEqual(values(lines, "Last 30 Days"),
                       [MetricValue(number: 1.75, kind: .dollars, estimated: true),
                        MetricValue(number: 450, kind: .count, label: "tokens")])
    }

    func testZeroUsageReadsZeroDollarsAndTokensNotNoData() {
        // The reported Grok "Today 0": a period with no usage is a measured zero, so every tile reads
        // "$0.00 · 0 tokens" — never a bare "0", and never "No data" (that's only for an unreadable
        // source). Fixed once in SpendTileMapper, so it holds for every provider that funnels through it.
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            CcusageDailyUsage(daily: [CcusageDay(date: "2026-02-19", totalTokens: 0, costUSD: nil)]),
            to: &lines,
            now: makeDate("2026-02-20T16:00:00.000Z")
        )

        let zero = [MetricValue(number: 0, kind: .dollars, estimated: true),
                    MetricValue(number: 0, kind: .count, label: "tokens")]
        XCTAssertEqual(values(lines, "Today"), zero)
        XCTAssertEqual(values(lines, "Yesterday"), zero)
        XCTAssertEqual(values(lines, "Last 30 Days"), zero)
    }

    func testUnpricedTokensShowTokensWithoutAFabricatedZeroDollar() {
        // A day with real tokens the runner couldn't price omits the dollar — its cost is unknown, not
        // zero — so the row shows just the labeled token count rather than a misleading "$0.00 ·".
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            CcusageDailyUsage(daily: [CcusageDay(date: "2026-02-20", totalTokens: 1_200_000, costUSD: nil)]),
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

        guard case .values(_, let vals, _, let expiriesAt) = mapped.lines.first(where: { $0.label == "Rate Limit Resets" }) else {
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

        guard case .values(_, _, _, let expiriesAt) = mapped.lines.first(where: { $0.label == "Rate Limit Resets" }) else {
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

        guard case .values(_, let vals, _, let expiriesAt) = mapped.lines.first(where: { $0.label == "Rate Limit Resets" }) else {
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
        guard case .values(_, let values, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }

    private func makeDate(_ value: String) -> Date {
        OpenUsageISO8601.date(from: value)!
    }
}

@MainActor
final class CodexProviderTests: XCTestCase {
    func testNoUsageDataBadgeIsDroppedWhenCcusageHasSpend() async {
        let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        // The live usage API returns nothing mappable (empty body -> no metric lines)...
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-home"]),
                files: FakeFiles(["/tmp/codex-home/auth.json": #"{"tokens":{"access_token":"token"}}"#]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: httpClient),
            ccusageRunner: CcusageRunner(
                processRunner: FakeProcessRunner(),
                homeDirectory: { URL(fileURLWithPath: "/Users/test") }
            ),
            now: { now }
        )

        let snapshot = await provider.refresh()

        // ...but local ccusage spend exists, so the snapshot shows the spend lines and NOT the
        // "No usage data" badge. Regression: the mapper used to append the badge *before* the ccusage
        // lines, leaving a contradictory badge-plus-spend snapshot.
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        XCTAssertFalse(snapshot.lines.contains { line in
            if case .badge(_, let value, _, _) = line { return value == "No usage data" }
            return false
        })
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }
}

final class CodexUsageClientRefreshTests: XCTestCase {
    func testRefreshReportsRequestFailureForUnrecognizedErrorBody() async {
        // A 400 carrying a non-OAuth body (an HTML proxy/WAF page) must surface as a request failure,
        // not "Token expired. Run `codex` to log in again." — re-login can't fix a transport/infra error.
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 400, headers: [:], body: Data("<html>Bad Gateway</html>".utf8)))
        let client = CodexUsageClient(http: http)
        do {
            _ = try await client.refreshToken("refresh")
            XCTFail("expected refreshToken to throw")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .requestFailed(400))
        } catch {
            XCTFail("expected CodexUsageError.requestFailed, got \(error)")
        }
    }

    func testRefreshReportsRequestFailureForNon4xxStatus() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        let client = CodexUsageClient(http: http)
        do {
            _ = try await client.refreshToken("refresh")
            XCTFail("expected refreshToken to throw")
        } catch let error as CodexUsageError {
            XCTAssertEqual(error, .requestFailed(503))
        } catch {
            XCTFail("expected CodexUsageError.requestFailed, got \(error)")
        }
    }

    func testRefreshStillMapsKnownOAuthCodeToSessionExpired() async {
        let body = Data(#"{"error":{"code":"refresh_token_expired"}}"#.utf8)
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 400, headers: [:], body: body))
        let client = CodexUsageClient(http: http)
        do {
            _ = try await client.refreshToken("refresh")
            XCTFail("expected refreshToken to throw")
        } catch let error as CodexAuthError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("expected CodexAuthError.sessionExpired, got \(error)")
        }
    }
}

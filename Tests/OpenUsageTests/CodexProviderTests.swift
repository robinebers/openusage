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
        XCTAssertEqual(text(mapped.lines, "Credits"), "$4.00 · 100 credits")
        XCTAssertNotNil(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Session")?.periodDurationMs, CodexUsageMapper.sessionPeriodMs)
    }

    func testAppendsTokenUsageLines() {
        var lines: [MetricLine] = []
        let usage = CcusageDailyUsage(daily: [
            CcusageDay(date: "2026-02-20", totalTokens: 150, costUSD: 0.75),
            CcusageDay(date: "2026-02-01", totalTokens: 300, costUSD: 1.0)
        ])

        CcusageSpendMapper.appendTokenUsage(
            usage,
            to: &lines,
            now: makeDate("2026-02-20T16:00:00.000Z")
        )

        XCTAssertEqual(text(lines, "Today"), "$0.75 · 150 tokens")
        XCTAssertEqual(text(lines, "Yesterday"), "0 tokens")
        XCTAssertEqual(text(lines, "Last 30 Days"), "$1.75 · 450 tokens")
    }

    // Regression: dollar amounts must group thousands (e.g. "$1,200.00") consistently with the
    // headline, which formats through `Formatters.currency`. Credit lines previously used a bare
    // `$%.2f` that dropped the separator.
    func testCreditsLabelGroupsThousands() {
        XCTAssertEqual(CodexUsageMapper.creditsLabel(remaining: 30000), "$1,200.00 · 30,000 credits")
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    private func text(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .text(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }

    private func makeDate(_ value: String) -> Date {
        OpenUsageISO8601.date(from: value)!
    }
}

final class CcusageRunnerTests: XCTestCase {
    func testParsesArrayOutput() {
        let usage = CcusageRunner.parseOutput("""
        [
          { "date": "2026-02-20", "totalTokens": 150, "costUSD": 0.75 }
        ]
        """)

        XCTAssertEqual(usage?.daily.first?.date, "2026-02-20")
        XCTAssertEqual(usage?.daily.first?.totalTokens, 150)
        XCTAssertEqual(usage?.daily.first?.costUSD, 0.75)
    }

    func testParsesObjectOutputAfterNoise() {
        let usage = CcusageRunner.parseOutput("""
        loading
        { "daily": [{ "date": "2026-02-20", "totalTokens": 150, "totalCost": 0.75 }] }
        """)

        XCTAssertEqual(usage?.daily.first?.totalTokens, 150)
        XCTAssertEqual(usage?.daily.first?.costUSD, 0.75)
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
        XCTAssertEqual(text(snapshot.lines, "Today"), "$0.25 · 150 tokens")
        XCTAssertFalse(snapshot.lines.contains { line in
            if case .badge(_, let value, _, _) = line { return value == "No usage data" }
            return false
        })
    }

    private func text(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .text(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }
}

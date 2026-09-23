import Foundation
import XCTest
@testable import OpenUsage

/// Capy runs Codex in the cloud on the user's ChatGPT subscription, so its usage only exists in Capy's
/// billing API. Only the `subscription` route's `codex/*` entries may reach the Codex card.
final class CapyCodexUsageScannerTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-09-23T08:50:00.000Z")!
    private let usageInstant = OpenUsageISO8601.date(from: "2026-09-21T12:00:00.000Z")!

    private let pricing = ModelPricing(
        supplement: PricingSupplement(pricing: [
            "gpt-5.6-sol": ModelRates(
                inputPerMillion: 5, outputPerMillion: 30, cacheWritePerMillion: 6.25, cacheReadPerMillion: 0.5
            )
        ]),
        primary: PricingCatalog(entries: [:]),
        secondary: PricingCatalog(entries: [:])
    )

    /// Shape captured from a live `GET /app/orgs/:org/billing/usage/breakdown` response.
    private let breakdown: [String: Any] = [
        "routes": [
            [
                "route": "subscription",
                "entries": [
                    ["key": "codex/gpt-5.6-sol", "tokens": [
                        "inputTokens": 1_000, "outputTokens": 50, "cacheReadTokens": 900, "cacheWriteTokens": 0
                    ]],
                    ["key": "claude/claude-opus-5", "tokens": [
                        "inputTokens": 7, "outputTokens": 7, "cacheReadTokens": 0, "cacheWriteTokens": 0
                    ]]
                ]
            ],
            [
                "route": "paid",
                "entries": [["key": "codex/gpt-5.6-sol", "tokens": [
                    "inputTokens": 5_000, "outputTokens": 5, "cacheReadTokens": 0, "cacheWriteTokens": 0
                ]]]
            ]
        ]
    ]

    func testRowsKeepOnlyCodexSubscriptionEntriesAndSplitCacheReadsOutOfInput() {
        let rows = CapyCodexUsageScanner.codexSubscriptionRows(breakdownPayload: breakdown)
        XCTAssertEqual(rows, [.init(
            model: "gpt-5.6-sol",
            tokens: TokenBreakdown(input: 100, cacheRead: 900, output: 50)
        )])
    }

    func testActiveDaysMarkEveryLocalDayAnActiveUTCBucketOverlaps() {
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = TimeZone(identifier: "Europe/Rome")!
        let series: [String: Any] = [
            "bucket": "day",
            "buckets": [
                ["start": "2026-09-20T00:00:00.000Z", "slices": [["key": "codex/gpt-5.6-sol", "credits": 0]]],
                ["start": "2026-09-21T00:00:00.000Z", "slices": [["key": "codex/gpt-5.6-sol", "credits": 12.5]]],
                ["start": "2026-09-22T00:00:00.000Z", "slices": [["key": "claude/claude-opus-5", "credits": 3]]]
            ]
        ]
        let days = CapyCodexUsageScanner.activeLocalDays(seriesPayload: series, since: .distantPast, calendar: rome)
        // 2026-09-21 UTC runs 02:00 Sep 21 → 01:59 Sep 22 in Rome.
        XCTAssertEqual(days.map { DailyUsageAccumulator.dayKey(from: $0, calendar: rome) }, ["2026-09-21", "2026-09-22"])
    }

    func testScanMintsDesktopSessionTokenAndPricesOnlyTheUsersCodexUsage() async throws {
        let home = try makeCapyHome()
        let usageDay = Calendar.current.startOfDay(for: usageInstant)
        let payload = try JSONSerialization.data(withJSONObject: breakdown)
        let http = RoutingHTTPClient { [usageInstant] request in
            let url = request.url.absoluteString
            if url.hasPrefix("https://clerk.capy.ai/v1/client/sessions/sess_1/tokens") {
                XCTAssertEqual(request.headers["Origin"], "capy://app")
                XCTAssertEqual(request.headers["Authorization"], "Bearer a.client.jwt")
                return Self.ok(#"{"object":"token","jwt":"session.jwt.value"}"#)
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer session.jwt.value")
            if url.hasSuffix("/app/organizations") { return Self.ok(#"[{"id":"org_1"}]"#) }
            if url.hasSuffix("/models/connections") { return Self.ok(Self.connections(accountID: "acct_capy")) }
            XCTAssertTrue(url.contains("principal=user_1"), url)
            if url.contains("/billing/usage/series?") {
                XCTAssertTrue(url.contains("route=subscription"), url)
                // An hourly bucket at the usage instant maps to exactly one local day in any time zone.
                let start = OpenUsageISO8601.string(from: usageInstant)
                return Self.ok(#"{"bucket":"hour","keys":[],"buckets":[{"start":"\#(start)","totalCredits":4,"slices":[{"key":"codex/gpt-5.6-sol","credits":4}]}]}"#)
            }
            if url.contains("/billing/usage/breakdown?from=\(OpenUsageISO8601.string(from: usageDay))") {
                return HTTPResponse(statusCode: 200, headers: [:], body: payload)
            }
            return Self.ok(#"{"routes":[]}"#)
        }
        let keyReader = FakeClaudeDesktopKeyReader(password: "capy-password", requiresInteraction: false)
        let scanner = CapyCodexUsageScanner(http: http, homeDirectory: { home }, keyReader: keyReader)

        let scan = await scanner.scan(now: now, pricing: pricing, codexAccountID: "acct_capy", allowInteraction: false)

        let day = DailyUsageAccumulator.dayKey(from: usageInstant)
        let tokens = TokenBreakdown(input: 100, cacheRead: 900, output: 50)
        let expectedCost = try XCTUnwrap(CodexUsagePricing.estimatedCost(pricing: pricing, model: "gpt-5.6-sol", tokens: tokens))
        let entry = try XCTUnwrap(scan?.series.daily.first { $0.date == day })
        XCTAssertEqual(entry.totalTokens, 1_050)
        XCTAssertEqual(try XCTUnwrap(entry.costUSD), expectedCost, accuracy: 1e-12)
        XCTAssertEqual(scan?.series.daily.map(\.totalTokens).reduce(0, +), 1_050)

        // A finished day is served from cache: the second scan re-mints and re-lists, but skips its breakdown.
        let breakdownCalls = http.requests.filter { $0.url.path.hasSuffix("/breakdown") }.count
        _ = await scanner.scan(now: now, pricing: pricing, codexAccountID: "acct_capy", allowInteraction: false)
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/breakdown") }.count, breakdownCalls)
    }

    func testUsageStaysOffCardsSignedInToADifferentChatGPTAccount() async throws {
        let home = try makeCapyHome()
        let http = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("clerk.capy.ai") { return Self.ok(#"{"jwt":"session.jwt.value"}"#) }
            if url.hasSuffix("/app/organizations") { return Self.ok(#"[{"id":"org_1"}]"#) }
            if url.hasSuffix("/models/connections") { return Self.ok(Self.connections(accountID: "acct_capy")) }
            XCTFail("usage must not be read for another account: \(url)")
            return Self.ok("{}")
        }
        let keyReader = FakeClaudeDesktopKeyReader(password: "capy-password", requiresInteraction: false)
        let scanner = CapyCodexUsageScanner(http: http, homeDirectory: { home }, keyReader: keyReader)

        let scan = await scanner.scan(now: now, pricing: pricing, codexAccountID: "acct_other", allowInteraction: false)

        XCTAssertNil(scan)
    }

    func testConnectedAccountsIgnoreOtherServicesAndDisconnectedCodex() {
        let payload: [String: Any] = ["subscriptions": [
            ["service": "codex", "state": "connected", "accountId": "acct_a"],
            ["service": "codex", "state": "not_connected", "accountId": "acct_b"],
            ["service": "supergrok", "state": "connected", "accountId": "acct_c"]
        ]]
        XCTAssertEqual(CapyCodexUsageScanner.connectedCodexAccountIDs(connectionsPayload: payload), ["acct_a"])
    }

    func testNoCapySessionNeverTouchesKeychainOrNetwork() async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let http = RoutingHTTPClient { _ in XCTFail("no request expected"); return Self.ok("{}") }
        let keyReader = FakeClaudeDesktopKeyReader(password: "unused", requiresInteraction: false)
        let scanner = CapyCodexUsageScanner(http: http, homeDirectory: { home }, keyReader: keyReader)

        let scan = await scanner.scan(now: now, pricing: pricing, codexAccountID: "acct_capy", allowInteraction: true)

        XCTAssertNil(scan)
        XCTAssertEqual(keyReader.calls, [])
    }

    func testBackgroundRefreshWithoutKeychainAccessSkipsQuietly() async throws {
        let home = try makeCapyHome()
        let http = RoutingHTTPClient { _ in XCTFail("no request expected"); return Self.ok("{}") }
        let keyReader = FakeClaudeDesktopKeyReader(password: "capy-password", requiresInteraction: true)
        let scanner = CapyCodexUsageScanner(http: http, homeDirectory: { home }, keyReader: keyReader)

        let scan = await scanner.scan(now: now, pricing: pricing, codexAccountID: "acct_capy", allowInteraction: false)

        XCTAssertNil(scan)
        XCTAssertEqual(keyReader.calls, [false])
    }

    // MARK: - Fixtures

    /// A home directory holding Capy's `session-credential.json`, encrypted the way Electron does it.
    private func makeCapyHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = home.appendingPathComponent(CapySession.sessionRelativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = try ClaudeDesktopAuthStore.deriveKey(password: "capy-password")
        let ciphertext = try ClaudeDesktopAuthStoreTests.encrypt(Data("a.client.jwt".utf8), key: key)
        let session: [String: Any] = [
            "version": 1, "userId": "user_1", "sessionId": "sess_1", "ciphertext": ciphertext.base64EncodedString()
        ]
        try JSONSerialization.data(withJSONObject: session).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    /// Shape captured from a live `GET /app/orgs/:org/models/connections` response.
    private static func connections(accountID: String) -> String {
        #"{"subscriptions":[{"service":"codex","state":"connected","enabled":true,"accountId":"\#(accountID)","plan":"Pro"}],"orgKeys":[]}"#
    }

    private static func ok(_ json: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
}

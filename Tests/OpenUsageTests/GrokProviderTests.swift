import XCTest
@testable import OpenUsage

@MainActor
final class GrokProviderTests: XCTestCase {
    func testRefreshFormEncodesReservedCharactersInRequestBody() async throws {
        let httpClient = RecordingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let client = GrokUsageClient(httpClient: httpClient)

        _ = try await client.refreshToken("refresh token&=+/?%", clientID: "client id&=+/?%")

        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(
            String(data: try XCTUnwrap(request.body), encoding: .utf8),
            "grant_type=refresh_token&client_id=client%20id%26%3D%2B%2F%3F%25" +
                "&refresh_token=refresh%20token%26%3D%2B%2F%3F%25"
        )
    }

    func testRefreshesExpiredTokenPersistsAuthAndFetchesUsage() async {
        let now = OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")!
        let files = FakeFiles([
            GrokAuthStore.authPath: """
            {
              "https://auth.x.ai::client": {
                "key": "expired-token",
                "refresh_token": "refresh-token",
                "oidc_client_id": "client-id",
                "expires_at": "2026-01-01T00:00:00.000Z",
                "custom_field": "keep-me"
              }
            }
            """
        ])
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                XCTAssertEqual(request.method, "POST")
                XCTAssertEqual(String(data: request.body ?? Data(), encoding: .utf8), "grant_type=refresh_token&client_id=client-id&refresh_token=refresh-token")
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }
            if request.url == GrokUsageClient.creditsConfigURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-token")
                XCTAssertEqual(request.headers["X-XAI-Token-Auth"], GrokUsageClient.tokenAuthHeader)
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
            }
            if request.url == GrokUsageClient.settingsURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-token")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: noLogScanner(),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "SuperGrok Heavy")
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertEqual(badge(snapshot.lines, "Pay as you go")?.text, "Disabled")

        let saved = GrokAuthStore.parseAuth(files.files[GrokAuthStore.authPath] ?? "")
        let entry = saved?["https://auth.x.ai::client"]
        XCTAssertEqual(entry?.key, "new-token")
        XCTAssertEqual(entry?.refreshToken, "new-refresh")
        XCTAssertEqual(entry?.expiresAt, "2026-02-02T01:00:00.000Z")
        let savedObject = GrokAuthStore.parseJSONObject(files.files[GrokAuthStore.authPath] ?? "")
        let rawEntry = savedObject?["https://auth.x.ai::client"] as? [String: Any]
        XCTAssertEqual(rawEntry?["custom_field"] as? String, "keep-me")
    }

    func testRetriesCreditsOnceAfterAuthError() async {
        let now = OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")!
        let files = FakeFiles([
            GrokAuthStore.authPath: """
            {
              "https://auth.x.ai::client": {
                "key": "old-token",
                "refresh_token": "refresh-token",
                "expires_at": "2026-06-01T00:00:00.000Z"
              }
            }
            """
        ])
        var creditsCalls = 0
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                creditsCalls += 1
                if creditsCalls == 1 {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
            }
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }
            if request.url == GrokUsageClient.settingsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: noLogScanner(),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "SuperGrok Heavy")
        let creditsAuths = httpClient.requests
            .filter { $0.url == GrokUsageClient.creditsConfigURL }
            .map { $0.headers["Authorization"] }
        XCTAssertEqual(creditsAuths, ["Bearer old-token", "Bearer new-token"])
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
    }

    func testWeeklyMeterAndPayAsYouGoComeFromCreditsConfig() async {
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                // The same plain GET the Grok CLI makes, with the standard auth headers.
                XCTAssertEqual(request.method, "GET")
                XCTAssertNil(request.body)
                XCTAssertEqual(request.headers["Authorization"], "Bearer token")
                XCTAssertEqual(request.headers["X-XAI-Token-Auth"], GrokUsageClient.tokenAuthHeader)
                XCTAssertEqual(request.headers["User-Agent"], "OpenUsage")
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.limit, 100)
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.resetsAt?.timeIntervalSince1970 ?? 0,
                       GrokCreditsFixtures.capturedPeriodEnd.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(badge(snapshot.lines, "Pay as you go")?.text, "Disabled")
        XCTAssertNil(snapshot.warning)
    }

    func testCreditsFetchFailureFailsTheProvider() async {
        // The credits config is the provider's only remote meter now — its failure is a provider
        // error, not a partial degrade.
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertNil(progress(snapshot.lines, "Weekly limit"))
    }

    func testMalformedBodyInsideHTTP200FailsTheProvider() async {
        // An HTTP 200 whose body isn't the shape we know is schema drift — fail loudly rather than
        // render a blank dashboard silently.
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"config":{}}"#.utf8))
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.errorCategory)
    }

    func testNonWeeklyPeriodShowsNoWeeklyLineAndNoWarning() async {
        // A not-yet-migrated (monthly-period) account is a valid state, not a failure: the Weekly
        // tile reads "No data" without the amber triangle, and the badge still renders.
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 200, headers: [:],
                                    body: GrokCreditsFixtures.responseBody(periodType: "USAGE_PERIOD_TYPE_MONTHLY"))
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertNil(progress(snapshot.lines, "Weekly limit"))
        XCTAssertEqual(badge(snapshot.lines, "Pay as you go")?.text, "Disabled")
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testRefreshAppendsLocalSpendTilesFromLog() async {
        let now = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
        // grok-build: 1M input @ $1 = $1.00 today; composer-2.5-fast: 1M output @ $15 = $15.00 yesterday.
        let log = """
        {"ts":"2026-06-18T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-06-18T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-17T09:00:00.000Z","pid":2,"msg":"model changed","ctx":{"model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-17T10:00:00.000Z","pid":2,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":0,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        """
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(["/home/test/.grok/logs/unified.jsonl": log]),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/test") }
        )
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner, now: now)

        let snapshot = await provider.refresh()

        // Existing credit lines stay; the three spend tiles are appended from the local log.
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 1.0, kind: .dollars, estimated: true), MetricValue(number: 1_000_000, kind: .count, label: "tokens")])
        XCTAssertEqual(values(snapshot.lines, "Yesterday"),
                       [MetricValue(number: 15.0, kind: .dollars, estimated: true), MetricValue(number: 1_000_000, kind: .count, label: "tokens")])
        XCTAssertEqual(values(snapshot.lines, "Last 30 Days"),
                       [MetricValue(number: 16.0, kind: .dollars, estimated: true), MetricValue(number: 2_000_000, kind: .count, label: "tokens")])
    }

    func testPeriodWithoutUsageLeavesTileUnbacked() async {
        // Regression for the reported "Today 0" bug: the log exists and has yesterday's usage, but no
        // inference ran today. An idle today is "No data" (no backing line), never a fabricated
        // "$0.00 · 0 tokens" that contradicts a live session. "No data" is also what a missing/unreadable
        // log produces — the two cases collapse to the same honest read.
        let now = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
        // Only yesterday (06-17) has an inference row; today (06-18) has none.
        let log = """
        {"ts":"2026-06-17T09:00:00.000Z","pid":2,"msg":"model changed","ctx":{"model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-17T10:00:00.000Z","pid":2,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":0,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        """
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(["/home/test/.grok/logs/unified.jsonl": log]),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/test") }
        )
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner, now: now)

        let snapshot = await provider.refresh()

        // No usage today → "No data" (no Today line). Yesterday and the 30-day total still render.
        XCTAssertNil(values(snapshot.lines, "Today"))
        XCTAssertNotNil(values(snapshot.lines, "Yesterday"))
        XCTAssertNotNil(values(snapshot.lines, "Last 30 Days"))
    }

    func testRefreshAppendsUsageTrendFromLog() async {
        let now = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
        // 1M input today (06-18), 1M output yesterday (06-17).
        let log = """
        {"ts":"2026-06-18T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-06-18T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-17T09:00:00.000Z","pid":2,"msg":"model changed","ctx":{"model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-17T10:00:00.000Z","pid":2,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":0,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        """
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(["/home/test/.grok/logs/unified.jsonl": log]),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/test") }
        )
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner, now: now)

        let snapshot = await provider.refresh()

        guard case .chart(_, let points, let note) = snapshot.lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("expected a Usage Trend chart line")
        }
        XCTAssertEqual(note, "From your Grok logs (estimated)")
        XCTAssertEqual(points.count, 31)
        XCTAssertEqual(points.last?.value, 1_000_000, "today's tokens land on the last bar")
        XCTAssertEqual(points[29].value, 1_000_000, "yesterday's tokens land on the second-to-last bar")
    }

    func testRefreshWithoutLogAppendsNoUsageTrend() async {
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes))

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.lines.first(where: { $0.label == "Usage Trend" }), "no log means no trend chart")
    }

    /// The stock happy-path routes: the captured weekly credits config and the plan name.
    private static func defaultRoutes(_ request: HTTPRequest) -> HTTPResponse {
        if request.url == GrokUsageClient.creditsConfigURL {
            return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
        }
        if request.url == GrokUsageClient.settingsURL {
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
        }
        return HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }

    private func makeProvider(
        httpClient: RecordingHTTPClient,
        scanner: GrokLogUsageScanner? = nil,
        now: Date = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
    ) -> GrokProvider {
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        ])
        return GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: scanner ?? noLogScanner(),
            now: { now },
            pricing: { TestPricing.bundled }
        )
    }

    private func noLogScanner() -> GrokLogUsageScanner {
        GrokLogUsageScanner(files: FakeFiles(), environment: FakeEnvironment(), homeDirectory: { URL(fileURLWithPath: "/home/none") })
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}

@MainActor
final class GrokWidgetDataStoreTests: XCTestCase {
    func testResolvesBadgeSnapshotIntoWidgetText() async {
        let provider = Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))
        let descriptor = WidgetDescriptor(
            id: "grok.payAsYouGo",
            providerID: provider.id,
            metricLabel: "Pay as you go",
            sample: WidgetData(title: "Pay as you go", icon: provider.icon, kind: .count, used: 0, limit: nil)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.badge(label: "Pay as you go", text: "2500 cap", colorHex: "#22c55e")]
            )
        )
        let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]), providers: [runtime])

        await store.refreshAll()

        XCTAssertEqual(store.data(for: descriptor).valueText, "2500 cap")
    }
}

private final class RecordingHTTPClient: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    private let handler: (HTTPRequest) throws -> HTTPResponse

    init(handler: @escaping (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt)
}

private func badge(_ lines: [MetricLine], _ label: String) -> (text: String, colorHex: String?)? {
    guard case .badge(_, let text, let colorHex, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (text, colorHex)
}

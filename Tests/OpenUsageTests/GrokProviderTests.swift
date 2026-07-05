import XCTest
@testable import OpenUsage

final class GrokUsageMapperTests: XCTestCase {
    func testMapsCreditsUsedAndPayAsYouGo() throws {
        let mapped = try GrokUsageMapper.mapBillingResponse(HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: billingBody(used: "2500", monthlyLimit: "10000", onDemandCap: "2500")
        ))

        XCTAssertEqual(progress(mapped.lines, "Credits used")?.used, 25)
        XCTAssertEqual(progress(mapped.lines, "Credits used")?.limit, 100)
        XCTAssertEqual(progress(mapped.lines, "Credits used")?.resetsAt, OpenUsageISO8601.date(from: "2026-06-01T00:00:00.000Z"))
        XCTAssertEqual(badge(mapped.lines, "Pay as you go")?.text, "2500 cap")
        XCTAssertEqual(badge(mapped.lines, "Pay as you go")?.colorHex, "#22c55e")
    }

    func testMapsDisabledPayAsYouGo() throws {
        let mapped = try GrokUsageMapper.mapBillingResponse(HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: billingBody(used: 4277, monthlyLimit: 60000, onDemandCap: 0)
        ))

        XCTAssertEqual(progress(mapped.lines, "Credits used")?.used ?? 0, 7.128, accuracy: 0.001)
        XCTAssertEqual(badge(mapped.lines, "Pay as you go")?.text, "Disabled")
        XCTAssertEqual(badge(mapped.lines, "Pay as you go")?.colorHex, "#a3a3a3")
    }

    func testMapsMissingOnDemandCapAsDisabled() throws {
        // A SuperGrok account with no pay-as-you-go omits `onDemandCap` entirely. Previously the
        // all-or-nothing guard threw `invalidResponse` ("Grok billing response changed."); it must
        // now render the Disabled badge instead, like a present cap of 0.
        let body: [String: Any] = [
            "config": [
                "used": ["val": 2500],
                "monthlyLimit": ["val": 10000],
                "billingPeriodEnd": "2026-06-01T00:00:00+00:00"
            ]
        ]
        let mapped = try GrokUsageMapper.mapBillingResponse(HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: body)
        ))

        XCTAssertEqual(progress(mapped.lines, "Credits used")?.used, 25)
        XCTAssertEqual(badge(mapped.lines, "Pay as you go")?.text, "Disabled")
        XCTAssertEqual(badge(mapped.lines, "Pay as you go")?.colorHex, "#a3a3a3")
    }
}

@MainActor
final class GrokProviderTests: XCTestCase {
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
            if request.url == GrokUsageClient.billingURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-token")
                XCTAssertEqual(request.headers["X-XAI-Token-Auth"], GrokUsageClient.tokenAuthHeader)
                return HTTPResponse(statusCode: 200, headers: [:], body: billingBody(used: 2500, monthlyLimit: 10000, onDemandCap: 0))
            }
            if request.url == GrokUsageClient.settingsURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-token")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
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
        XCTAssertEqual(progress(snapshot.lines, "Credits used")?.used, 25)
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

    func testRetriesBillingOnceAfterAuthError() async {
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
        var billingCalls = 0
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.billingURL {
                billingCalls += 1
                if billingCalls == 1 {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: billingBody(used: 2500, monthlyLimit: 10000, onDemandCap: 0))
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
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
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
        let billingAuths = httpClient.requests
            .filter { $0.url == GrokUsageClient.billingURL }
            .map { $0.headers["Authorization"] }
        XCTAssertEqual(billingAuths, ["Bearer old-token", "Bearer new-token"])

        // The weekly call runs after billing and must carry the rotated token, not the one the
        // refresh cycle already proved dead.
        let creditsAuths = httpClient.requests
            .filter { $0.url == GrokUsageClient.creditsConfigURL }
            .map { $0.headers["Authorization"] }
        XCTAssertEqual(creditsAuths, ["Bearer new-token"])
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
    }

    func testWeeklyMeterComesFromCreditsConfig() async {
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                // The endpoint's contract, pinned exactly: any drift in the framed request bytes is a
                // protocol regression (the server rejects an empty message with grpc-status 13).
                XCTAssertEqual(request.method, "POST")
                XCTAssertEqual(request.body, Data([0x00, 0x00, 0x00, 0x00, 0x02, 0x08, 0x01]))
                XCTAssertEqual(request.headers["Content-Type"], "application/grpc-web+proto")
                XCTAssertEqual(request.headers["X-Grpc-Web"], "1")
                XCTAssertEqual(request.headers["Authorization"], "Bearer token")
                XCTAssertEqual(request.headers["X-XAI-Token-Auth"], GrokUsageClient.tokenAuthHeader)
                XCTAssertEqual(request.headers["User-Agent"], "OpenUsage", "Cloudflare 403s unrecognized agents")
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
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(progress(snapshot.lines, "Credits used")?.used, 25, "monthly meter rides along unchanged")
    }

    func testWeeklyFetchFailureKeepsMonthlyAndRaisesWarning() async {
        // The credits endpoint serves grok.com's website and can change independently of the CLI's
        // API. Its failure must degrade to the amber header warning — never take down the monthly
        // meter and spend tiles that still work.
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertNil(progress(snapshot.lines, "Weekly limit"))
        XCTAssertEqual(progress(snapshot.lines, "Credits used")?.used, 25)
        XCTAssertEqual(badge(snapshot.lines, "Pay as you go")?.text, "Disabled")
        XCTAssertEqual(snapshot.warning, GrokUsageMapper.weeklyUnavailableWarning)
        XCTAssertNil(snapshot.errorCategory, "a weekly-only failure must not mark the provider errored")
    }

    func testWeeklyGRPCErrorInsideHTTP200RaisesWarning() async {
        // gRPC reports failures inside an HTTP 200 via the trailer — including auth-ish statuses the
        // HTTP-status-based retry can't see. Billing already proved the token, so this is a partial
        // failure (warning), not an app-wide auth error.
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 200, headers: [:],
                                    body: GrokCreditsFixtures.errorResponseBody(status: 16, message: "unauthenticated"))
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertNil(progress(snapshot.lines, "Weekly limit"))
        XCTAssertEqual(progress(snapshot.lines, "Credits used")?.used, 25)
        XCTAssertEqual(snapshot.warning, GrokUsageMapper.weeklyUnavailableWarning)
    }

    func testNonWeeklyPeriodShowsNoWeeklyLineAndNoWarning() async {
        // A not-yet-migrated (monthly-period) account is a valid state, not a failure: the Weekly
        // tile reads "No data" without the amber triangle.
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 200, headers: [:],
                                    body: GrokCreditsFixtures.responseBody(periodType: 1))
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertNil(progress(snapshot.lines, "Weekly limit"))
        XCTAssertNil(snapshot.warning)
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
        XCTAssertEqual(progress(snapshot.lines, "Credits used")?.used, 25)
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

    /// The stock happy-path routes: billing (25% used, no pay-as-you-go), the plan name, and the
    /// captured weekly credits config.
    private static func defaultRoutes(_ request: HTTPRequest) -> HTTPResponse {
        if request.url == GrokUsageClient.billingURL {
            return HTTPResponse(statusCode: 200, headers: [:], body: billingBody(used: 2500, monthlyLimit: 10000, onDemandCap: 0))
        }
        if request.url == GrokUsageClient.settingsURL {
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
        }
        if request.url == GrokUsageClient.creditsConfigURL {
            return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
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

private func billingBody(used: Any, monthlyLimit: Any, onDemandCap: Any) -> Data {
    let body: [String: Any] = [
        "config": [
            "used": ["val": used],
            "monthlyLimit": ["val": monthlyLimit],
            "onDemandCap": ["val": onDemandCap],
            "billingPeriodEnd": "2026-06-01T00:00:00+00:00"
        ]
    ]
    return try! JSONSerialization.data(withJSONObject: body)
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

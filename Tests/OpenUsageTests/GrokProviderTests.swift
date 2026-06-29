import XCTest
@testable import OpenUsage

final class GrokAuthStoreTests: XCTestCase {
    func testReadsTokenExpiryFromJWT() {
        let store = GrokAuthStore(now: { OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")! })
        let token = makeJWT(exp: 1_770_000_000)

        let expiry = store.tokenExpiresAt(token)

        XCTAssertEqual(expiry?.timeIntervalSince1970, 1_770_000_000)
    }

    func testLoadsAuthCandidatesFromGrokAuthFile() throws {
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh"}}"#
        ])
        let store = GrokAuthStore(files: files)

        let candidates = try store.loadAuthCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.token, "token")
        XCTAssertEqual(candidates.first?.entryKey, "https://auth.x.ai::client")
    }

    func testSaveRefusesToOverwriteACorruptAuthFile() throws {
        // A present-but-corrupt auth.json must NOT be silently rebuilt from in-memory state (which
        // would drop other accounts' entries). save() must throw and leave the file untouched.
        let validJSON = #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        let files = FakeFiles([GrokAuthStore.authPath: validJSON])
        let store = GrokAuthStore(files: files, now: { OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")! })
        var state = try XCTUnwrap(store.loadAuthCandidates().first)
        state.entry.key = "rotated-token"

        // Corrupt the file on disk, then attempt to persist the rotation.
        let corrupt = "{ not valid json"
        files.files[GrokAuthStore.authPath] = corrupt

        XCTAssertThrowsError(try store.save(state))
        XCTAssertEqual(files.files[GrokAuthStore.authPath], corrupt, "corrupt file must be left untouched, not clobbered")
    }
}

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

final class GrokLogUsageScannerTests: XCTestCase {
    private let since = OpenUsageISO8601.date(from: "2026-06-01T00:00:00.000Z")!

    func testAttributesTokensToPerProcessModelAndPrices() {
        // pid 100 is on grok-build, pid 200 on grok-composer-2.5-fast; each token row prices against
        // its own process's current model.
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":100,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-10T09:00:00.000Z","pid":200,"msg":"model changed","ctx":{"model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":100,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        {"ts":"2026-06-10T11:00:00.000Z","pid":200,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since)

        let day = usage.daily.first { $0.date == "2026-06-10" }
        XCTAssertEqual(day?.totalTokens, 4_000_000)
        // grok-build: 1M input @ $1 + 1M output @ $2 = $3. composer-2.5-fast: 1M @ $3 + 1M @ $15 = $18.
        XCTAssertEqual(day?.costUSD ?? 0, 21.0, accuracy: 0.0001)
    }

    func testTracksMidProcessModelSwitch() {
        let log = """
        {"ts":"2026-06-12T08:00:00.000Z","pid":7,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-06-12T09:00:00.000Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-12T10:00:00.000Z","pid":7,"msg":"model changed","ctx":{"model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T11:00:00.000Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since)

        // First row priced as grok-build ($1/M input), second after the switch as composer-2.5-fast ($3/M).
        XCTAssertEqual(usage.daily.first?.costUSD ?? 0, 4.0, accuracy: 0.0001)
    }

    func testUsesCachedReadRateForCachedPromptTokens() {
        // 800k of the 1M prompt tokens are cache reads (grok-build: $0.2/M read vs $1/M input).
        let log = """
        {"ts":"2026-06-12T08:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-06-12T09:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":800000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since)

        // 200k input @ $1/M ($0.2) + 800k cache read @ $0.2/M ($0.16) = $0.36.
        XCTAssertEqual(usage.daily.first?.costUSD ?? 0, 0.36, accuracy: 0.0001)
    }

    func testSkipsRowsWithoutTokenFieldsAndOutsideWindow() {
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-05-30T09:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"loop_index":3,"model_elapsed_ms":10}}
        {"ts":"2026-06-10T11:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":500000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since)

        // Only the in-window, token-bearing row counts (the pre-window row and the token-less row drop).
        XCTAssertEqual(usage.daily.count, 1)
        XCTAssertEqual(usage.daily.first?.totalTokens, 500_000)
    }

    func testUnpricedModelLeavesCostNil() {
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-unknown-model"}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since)

        XCTAssertEqual(usage.daily.first?.totalTokens, 1_000_000)
        XCTAssertNil(usage.daily.first?.costUSD)
    }

    func testScanReadsGrokHomeOverride() async {
        let files = FakeFiles([
            "/custom/grok/logs/unified.jsonl": """
            {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
            {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
            """
        ])
        let scanner = GrokLogUsageScanner(
            files: files,
            environment: FakeEnvironment(["GROK_HOME": "/custom/grok"]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") }
        )

        let usage = await scanner.scan(daysBack: 30, now: OpenUsageISO8601.date(from: "2026-06-18T00:00:00.000Z")!)

        XCTAssertEqual(usage?.daily.first?.totalTokens, 1_000_000)
    }

    func testScanReturnsNilWhenLogMissing() async {
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") }
        )

        let usage = await scanner.scan()
        XCTAssertNil(usage)
    }
}

final class GrokPricingAliasTests: XCTestCase {
    func testGrokCLIModelIDsResolveToManifestEntries() {
        XCTAssertEqual(CursorPricing.canonicalModel(for: "grok-build"), "grok-build-0.1")
        XCTAssertEqual(CursorPricing.canonicalModel(for: "grok-composer-2.5-fast"), "composer-2.5-fast")
        XCTAssertNotNil(CursorPricing.pricingEntry(for: "grok-build"))
        XCTAssertNotNil(CursorPricing.pricingEntry(for: "grok-composer-2.5-fast"))
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
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: noLogScanner(),
            now: { now }
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
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: noLogScanner(),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "SuperGrok Heavy")
        let billingAuths = httpClient.requests
            .filter { $0.url == GrokUsageClient.billingURL }
            .map { $0.headers["Authorization"] }
        XCTAssertEqual(billingAuths, ["Bearer old-token", "Bearer new-token"])
    }

    func testRefreshAppendsLocalSpendTilesFromLog() async {
        let now = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        ])
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.billingURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: billingBody(used: 2500, monthlyLimit: 10000, onDemandCap: 0))
            }
            if request.url == GrokUsageClient.settingsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
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
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: scanner,
            now: { now }
        )

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
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        ])
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.billingURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: billingBody(used: 2500, monthlyLimit: 10000, onDemandCap: 0))
            }
            if request.url == GrokUsageClient.settingsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
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
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: scanner,
            now: { now }
        )

        let snapshot = await provider.refresh()

        // No usage today → "No data" (no Today line). Yesterday and the 30-day total still render.
        XCTAssertNil(values(snapshot.lines, "Today"))
        XCTAssertNotNil(values(snapshot.lines, "Yesterday"))
        XCTAssertNotNil(values(snapshot.lines, "Last 30 Days"))
    }

    func testRefreshAppendsUsageTrendFromLog() async {
        let now = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        ])
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.billingURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: billingBody(used: 2500, monthlyLimit: 10000, onDemandCap: 0))
            }
            if request.url == GrokUsageClient.settingsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
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
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: scanner,
            now: { now }
        )

        let snapshot = await provider.refresh()

        guard case .chart(_, let points, let note) = snapshot.lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("expected a Usage Trend chart line")
        }
        XCTAssertEqual(note, "Estimated from local logs at API rates")
        XCTAssertEqual(points.count, 31)
        XCTAssertEqual(points.last?.value, 1_000_000, "today's tokens land on the last bar")
        XCTAssertEqual(points[29].value, 1_000_000, "yesterday's tokens land on the second-to-last bar")
    }

    func testRefreshWithoutLogAppendsNoUsageTrend() async {
        let now = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        ])
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.billingURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: billingBody(used: 2500, monthlyLimit: 10000, onDemandCap: 0))
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
            now: { now }
        )

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.lines.first(where: { $0.label == "Usage Trend" }), "no log means no trend chart")
    }

    private func noLogScanner() -> GrokLogUsageScanner {
        GrokLogUsageScanner(files: FakeFiles(), environment: FakeEnvironment(), homeDirectory: { URL(fileURLWithPath: "/home/none") })
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
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

private func makeJWT(exp: Int) -> String {
    let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
    let payload = base64URL(Data(#"{"exp":\#(exp)}"#.utf8))
    return "\(header).\(payload).signature"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

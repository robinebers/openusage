import XCTest
@testable import OpenUsage

// MARK: - CSV parser

final class CursorCSVParserTests: XCTestCase {
    func testParsesQuotedCommasEscapedQuotesAndEmbeddedNewlines() {
        let csv = """
        Date,Model,Note
        2026-01-01T00:00:00Z,"composer-1","a, b ""quoted"" c"
        2026-01-02T00:00:00Z,composer-1,"line one
        line two"
        """
        var records: [[String: String]] = []
        CursorCSVParser.forEachRecord(in: csv) { records.append($0) }

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["Note"], #"a, b "quoted" c"#)
        XCTAssertEqual(records[1]["Note"], "line one\nline two")
        XCTAssertEqual(records[1]["Model"], "composer-1")
    }

    func testParsesTrailingPartialRowWithoutNewline() {
        let csv = "Date,Model\n2026-01-01T00:00:00Z,composer-1"
        var records: [[String: String]] = []
        CursorCSVParser.forEachRecord(in: csv) { records.append($0) }

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["Date"], "2026-01-01T00:00:00Z")
        XCTAssertEqual(records[0]["Model"], "composer-1")
    }

    func testUsageCSVMapsColumnsToPricedRows() {
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        2026-01-01T00:00:00Z,composer-1,No,0,0,0,1000000,Included
        ,skipped-no-date,No,0,0,0,0,Included
        """
        let rows = CursorUsageCSV.parse(csv: csv)

        XCTAssertEqual(rows.count, 1) // the dateless row is skipped
        XCTAssertEqual(rows[0].model, "composer-1")
        XCTAssertEqual(rows[0].tokens.output, 1_000_000)
        // composer-1 output is $10/M → 1M output = $10.
        XCTAssertEqual(rows[0].imputedCostDollars, 10.0, accuracy: 1e-9)
    }
}

// MARK: - Manifest + pricing

final class CursorPricingTests: XCTestCase {
    func testBundledManifestLoadsAndResolvesKnownAlias() {
        XCTAssertFalse(CursorPricing.manifest.isEmpty, "model_manifest.json should load from Bundle.module")
        // A thinking variant resolves to its canonical entry via the alias rules.
        XCTAssertEqual(CursorPricing.canonicalModel(for: "claude-4.5-sonnet-thinking"), "claude-4.5-sonnet")
        XCTAssertNotNil(CursorPricing.pricingEntry(for: "claude-4.5-sonnet-thinking"))
    }

    func testUnknownModelHasNoPricing() {
        XCTAssertNil(CursorPricing.canonicalModel(for: "totally-unknown-model-xyz"))
        XCTAssertNil(CursorPricing.pricingEntry(for: "totally-unknown-model-xyz"))
    }

    /// Synced from cursorcat (manifest 2026-06-09): Claude Fable 5 is priced at 2x standard
    /// Claude 4.8 Opus — the same rate as the 4.8 Opus fast tier — and its thinking/effort
    /// slug variants all resolve to the one canonical entry.
    func testClaudeFable5PricingAndAliases() throws {
        XCTAssertEqual(CursorPricing.canonicalModel(for: "claude-fable-5"), "claude-fable-5")
        XCTAssertEqual(CursorPricing.canonicalModel(for: "claude-fable-5-thinking-xhigh"), "claude-fable-5")

        let fable = try XCTUnwrap(CursorPricing.pricingEntry(for: "claude-fable-5-thinking"))
        XCTAssertEqual(fable.familyDisplayName, "Claude Fable 5")
        XCTAssertEqual(fable.inputPerMillion, 10.0)
        XCTAssertEqual(fable.cacheWritePerMillion, 12.5)
        XCTAssertEqual(fable.cacheReadPerMillion, 1.0)
        XCTAssertEqual(fable.outputPerMillion, 50.0)

        let opus48 = try XCTUnwrap(CursorPricing.pricingEntry(for: "claude-opus-4-8"))
        XCTAssertEqual(fable.inputPerMillion, opus48.inputPerMillion * 2)
        XCTAssertEqual(fable.cacheWritePerMillion, opus48.cacheWritePerMillion * 2)
        XCTAssertEqual(fable.cacheReadPerMillion, opus48.cacheReadPerMillion * 2)
        XCTAssertEqual(fable.outputPerMillion, opus48.outputPerMillion * 2)
    }

    /// GLM 5.2 (Z.ai) was added to Cursor's pricing page after the 2026-06-09 manifest sync. It ships
    /// as two reasoning-effort variants — `glm-5.2-high` and `glm-5.2-max` — which both resolve to the
    /// one canonical `glm-5.2` entry. The pricing page lists no separate cache-write price, so cache
    /// write is billed at the input rate ($1.4), matching how the Gemini/GPT entries are filled.
    func testGLM52PricingAndAliases() throws {
        XCTAssertEqual(CursorPricing.canonicalModel(for: "glm-5.2"), "glm-5.2")
        XCTAssertEqual(CursorPricing.canonicalModel(for: "glm-5.2-high"), "glm-5.2")
        XCTAssertEqual(CursorPricing.canonicalModel(for: "glm-5.2-max"), "glm-5.2")

        let glm = try XCTUnwrap(CursorPricing.pricingEntry(for: "glm-5.2-max"))
        XCTAssertEqual(glm.familyDisplayName, "GLM 5.2")
        XCTAssertEqual(glm.inputPerMillion, 1.4)
        XCTAssertEqual(glm.cacheWritePerMillion, 1.4)
        XCTAssertEqual(glm.cacheReadPerMillion, 0.26)
        XCTAssertEqual(glm.outputPerMillion, 4.4)

        // 1M output at $4.4/M → $4.40; a slug outside the high/max allowlist stays unpriced ($0).
        let outputOnly = CursorTokenUsage(inputCacheWrite: 0, inputNoCacheWrite: 0, cacheRead: 0, output: 1_000_000)
        XCTAssertEqual(CursorPricing.estimatedCostDollars(model: "glm-5.2-high", maxMode: false, tokens: outputOnly), 4.4, accuracy: 1e-9)
        XCTAssertNil(CursorPricing.canonicalModel(for: "glm-5.2-bogus"))
        XCTAssertEqual(CursorPricing.estimatedCostDollars(model: "glm-5.2-bogus", maxMode: false, tokens: outputOnly), 0, accuracy: 1e-9)
    }

    func testCostSumsAllFourBucketsAndUnpricedIsZero() {
        let entry = try! XCTUnwrap(CursorPricing.pricingEntry(for: "composer-1"))
        let tokens = CursorTokenUsage(
            inputCacheWrite: 1_000_000,
            inputNoCacheWrite: 1_000_000,
            cacheRead: 1_000_000,
            output: 1_000_000
        )
        let expected = entry.cacheWritePerMillion + entry.inputPerMillion + entry.cacheReadPerMillion + entry.outputPerMillion
        XCTAssertEqual(CursorPricing.estimatedCostDollars(model: "composer-1", maxMode: false, tokens: tokens), expected, accuracy: 1e-9)

        XCTAssertEqual(CursorPricing.estimatedCostDollars(model: "nope", maxMode: false, tokens: tokens), 0, accuracy: 1e-9)
    }
}

// MARK: - Range aggregation

final class CursorSpendRangeTests: XCTestCase {
    func testAppendSpendLinesBucketsRowsByLocalDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let startOfLast30 = cal.date(byAdding: .day, value: -29, to: startOfToday)!

        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100),                                              // today
            makeRow(date: cal.date(byAdding: .day, value: -1, to: now)!, cost: 2.00, tokens: 200),    // yesterday
            makeRow(date: startOfLast30, cost: 0.50, tokens: 50),                                     // -29d edge: last30 only
            makeRow(date: cal.date(byAdding: .day, value: -40, to: now)!, cost: 5.00, tokens: 999)    // old (provider scopes the fetch)
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, to: &lines)

        // Combined cost + tokens, server-priced so the dollar value is not marked estimated.
        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 1.00, kind: .dollars), MetricValue(number: 100, kind: .count, label: "tokens")])
        XCTAssertEqual(values(lines, "Yesterday"), [MetricValue(number: 2.00, kind: .dollars), MetricValue(number: 200, kind: .count, label: "tokens")])
        // Last 30 Days sums every fetched day (the provider scopes the CSV to a 30-day window).
        XCTAssertEqual(values(lines, "Last 30 Days"), [MetricValue(number: 8.50, kind: .dollars), MetricValue(number: 1349, kind: .count, label: "tokens")])
    }

    func testZeroActivityLeavesTilesUnbacked() {
        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: [], now: Date(), to: &lines)

        // The export fetched but had no rows: every period is idle, so no spend tile is appended and the
        // tiles fall back to "No data" — not a fabricated "$0.00 · 0 tokens" ("No data" is also what a
        // failed export produces; see the provider test).
        XCTAssertNil(values(lines, "Today"))
        XCTAssertNil(values(lines, "Yesterday"))
        XCTAssertNil(values(lines, "Last 30 Days"))
    }

    func testAppendSpendLinesAlsoAppendsUsageTrend() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cal = Calendar.current
        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100),                                           // today
            makeRow(date: cal.date(byAdding: .day, value: -1, to: now)!, cost: 2.00, tokens: 200)  // yesterday
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, to: &lines)

        guard case .chart(let label, let points, let note) = lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("expected a Usage Trend chart line")
        }
        XCTAssertEqual(label, "Usage Trend")
        // Cursor's tokens come from the server-priced CSV, so the note names that source, not local logs.
        XCTAssertEqual(note, "From your Cursor usage history")
        XCTAssertEqual(points.count, 31, "one bar per calendar day across the 31-day window")
        XCTAssertEqual(points.last?.value, 100, "today's tokens land on the last bar")
        XCTAssertEqual(points[29].value, 200, "yesterday's tokens land on the second-to-last bar")
    }

    func testNoRowsLeavesNoUsageTrend() {
        // A fetched-but-empty export leaves the spend tiles unbacked and gives the trend nothing to draw,
        // so no chart line is appended (the row falls back to "No data").
        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: [], now: Date(), to: &lines)
        XCTAssertNil(lines.first(where: { $0.label == "Usage Trend" }))
    }

    func testUnknownModelsAttachToTheRightPeriods() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cal = Calendar.current
        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100, model: "composer-1"),                                  // priced, today
            makeRow(date: now, cost: 0.00, tokens: 50, model: "totally-unknown-model-xyz"),                     // unknown, today
            makeRow(date: cal.date(byAdding: .day, value: -1, to: now)!, cost: 2.00, tokens: 200, model: "composer-1"), // priced, yesterday
            makeRow(date: cal.date(byAdding: .day, value: -3, to: now)!, cost: 0.00, tokens: 80, model: "another-unknown-abc") // unknown, last30 only
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, to: &lines)

        // Today carries its own unknown model; a fully-priced Yesterday stays clean; Last 30 Days carries
        // the de-duplicated, sorted union across the whole window.
        XCTAssertEqual(unknown(lines, "Today"), ["totally-unknown-model-xyz"])
        XCTAssertEqual(unknown(lines, "Yesterday"), [])
        XCTAssertEqual(unknown(lines, "Last 30 Days"), ["another-unknown-abc", "totally-unknown-model-xyz"])
    }

    func testUnknownModelWithZeroTokensIsNotFlagged() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // A zero-token row of an unknown model changes no cost, so it never raises the warning. The day
        // also has real priced usage, so the tile exists (an all-idle day gets no tile at all) — proving
        // the zero-token unknown is filtered out, not just hidden by an absent tile.
        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100, model: "composer-1"),
            makeRow(date: now, cost: 0.00, tokens: 0, model: "totally-unknown-model-xyz")
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, to: &lines)

        XCTAssertNotNil(values(lines, "Today"), "the priced row keeps the tile present")
        XCTAssertEqual(unknown(lines, "Today"), [])
        XCTAssertEqual(unknown(lines, "Last 30 Days"), [])
    }

    private func unknown(_ lines: [MetricLine], _ label: String) -> [String]? {
        guard case .values(_, _, _, _, let unknownModels) = lines.first(where: { $0.label == label }) else { return nil }
        return unknownModels
    }

    private func makeRow(date: Date, cost: Double, tokens: Int, model: String = "composer-1") -> CursorUsageCSVRow {
        CursorUsageCSVRow(
            date: date,
            model: model,
            maxMode: false,
            tokens: CursorTokenUsage(inputCacheWrite: 0, inputNoCacheWrite: tokens, cacheRead: 0, output: 0),
            imputedCostDollars: cost
        )
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}

// MARK: - Provider integration + render shape

@MainActor
final class CursorSpendProviderTests: XCTestCase {
    func testSpendTrackingEnabledDownloadsCSVExposesSpendTilesAndFlagsUnknownModels() async {
        // Spend tracking is back on (issue #758): the provider downloads the usage CSV, exposes the
        // spend-tile + trend descriptors, and emits Today / Yesterday / Last 30 Days / Usage Trend lines
        // alongside the live quota meters. A row that used a model the manifest can't price carries that
        // model's name so the tile can warn its cost is incomplete.
        XCTAssertTrue(CursorProvider.spendTrackingEnabled, "this regression guards the enabled state")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        let todayStr = iso.string(from: now)
        let yesterdayStr = iso.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now)!)
        // A priced model and an unknown one both used today, plus a priced row yesterday.
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        \(todayStr),composer-1,No,0,1000000,0,0,Included
        \(todayStr),totally-unknown-model-xyz,No,0,500000,0,0,Included
        \(yesterdayStr),composer-1,No,0,200000,0,0,Included
        """

        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("export-usage-events-csv") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(csv.utf8))
            }
            if url.contains("GetCurrentPeriodUsage") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": { "limit": 40000, "remaining": 32000, "totalPercentUsed": 20 }
                }
                """.utf8))
            }
            if url.contains("GetPlanInfo") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8))
            }
            if url.contains("GetCreditGrantsBalance") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(http.requests.contains { $0.url.absoluteString.contains("export-usage-events-csv") },
                      "spend tracking is enabled — Cursor must download the usage CSV")
        // Live quota meter survives; spend tiles + trend are present.
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Total usage" })
        for label in ["Today", "Yesterday", "Last 30 Days", "Usage Trend"] {
            XCTAssertNotNil(snapshot.lines.first { $0.label == label }, "\(label) line must be present")
        }
        let ids = Set(provider.widgetDescriptors.map(\.id))
        for id in ["cursor.today", "cursor.yesterday", "cursor.last30", "cursor.trend"] {
            XCTAssertTrue(ids.contains(id), "\(id) descriptor must be present")
        }

        // The unknown model rode onto Today (and the Last 30 Days union); a fully-priced Yesterday stays clean.
        XCTAssertEqual(unknownModels(snapshot.lines, "Today"), ["totally-unknown-model-xyz"])
        XCTAssertEqual(unknownModels(snapshot.lines, "Yesterday"), [])
        XCTAssertEqual(unknownModels(snapshot.lines, "Last 30 Days"), ["totally-unknown-model-xyz"])
    }

    private func unknownModels(_ lines: [MetricLine], _ label: String) -> [String]? {
        guard case .values(_, _, _, _, let unknownModels) = lines.first(where: { $0.label == label }) else { return nil }
        return unknownModels
    }

    func testSpendTileRendersCombinedCostAndTokensWithValueTooltip() async {
        let cursor = CursorProvider()
        // Spend tiles are gated off the live provider (issue #758), so source the descriptor from the
        // shared factory — this keeps the combined "cost · tokens" render shape covered for re-enable.
        let descriptor = try! XCTUnwrap(WidgetDescriptor.spendTiles(provider: cursor.provider).first { $0.id == "cursor.today" })

        // The combined tile joins the dollar and the labeled token count. The render shape for a zero
        // line is still "$0.00 · 0 tokens" — the mapper no longer produces these (an idle period is left
        // unbacked → "No data"), but a provider that reports a real $0.00 (e.g. OpenRouter) still renders
        // it rather than hiding the figure.
        let cases: [(Double, Int, String, String)] = [
            (12.34, 891_000, "$12.34", "$12.34 · 891K tokens"),
            (0.0, 0, "$0.00", "$0.00 · 0 tokens")
        ]
        for (dollars, tokens, expectedValue, expectedDetail) in cases {
            let runtime = TestProviderRuntime(
                provider: cursor.provider,
                descriptors: [descriptor],
                snapshot: ProviderSnapshot(
                    providerID: cursor.provider.id,
                    displayName: cursor.provider.displayName,
                    lines: [.values(label: "Today", values: [
                        MetricValue(number: dollars, kind: .dollars),
                        MetricValue(number: Double(tokens), kind: .count, label: "tokens")
                    ])]
                )
            )
            let defaults = isolatedDefaults("render-\(expectedValue)")
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [cursor.provider], descriptors: [descriptor]),
                providers: [runtime],
                cache: isolatedCache(defaults),
                defaults: defaults
            )
            await store.refreshAll()

            store.meterStyle = .remaining
            let remaining = store.data(for: descriptor)
            store.meterStyle = .used
            let used = store.data(for: descriptor)

            XCTAssertTrue(remaining.hasData)
            XCTAssertEqual(remaining.valueText, expectedValue)
            XCTAssertEqual(remaining.unboundedDetail, expectedDetail)
            // Cursor spend is server-priced, so the combined tile carries no local-estimate note.
            XCTAssertNil(remaining.infoNote)
            // Unbounded: identical under both meter styles.
            XCTAssertEqual(used.valueText, remaining.valueText)
            XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
            XCTAssertEqual(used.infoNote, remaining.infoNote)
        }
    }

    // MARK: helpers

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.CursorSpend.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func isolatedCache(_ defaults: UserDefaults) -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
    }
}

// MARK: - Client request contract

final class CursorUsageClientRequestTests: XCTestCase {
    // The provider-level CSV integration tests were removed when spend tracking was disabled (issue
    // #758), but `CursorUsageClient.fetchUsageCSV` is kept intact for re-enable. Pin its request contract
    // directly at the client level — endpoint, epoch-ms range, `strategy=tokens`, the session cookie, and
    // `Accept: text/csv` — so a silent regression in URL/header construction can't slip through while the
    // feature is off (this test runs regardless of `CursorProvider.spendTrackingEnabled`).
    func testFetchUsageCSVBuildsTokenStrategyRequestWithSessionCookie() async throws {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("Date,Model\n".utf8))
        }

        let response = try await CursorUsageClient(http: http).fetchUsageCSV(
            accessToken: accessToken,
            start: Date(timeIntervalSince1970: 1_000),   // 1_000_000 ms
            end: Date(timeIntervalSince1970: 2_000)      // 2_000_000 ms
        )

        XCTAssertEqual(response?.statusCode, 200)
        // A nil session would skip the HTTP call entirely, so requiring a recorded request guards that
        // the assertions below actually ran against a real request.
        let request = try XCTUnwrap(http.requests.first, "fetchUsageCSV must issue a request")
        let url = request.url.absoluteString
        XCTAssertTrue(url.contains("export-usage-events-csv"), "hits the CSV export endpoint")
        XCTAssertTrue(url.contains("startDate=1000000"), "start as epoch-ms query param")
        XCTAssertTrue(url.contains("endDate=2000000"), "end as epoch-ms query param")
        XCTAssertTrue(url.contains("strategy=tokens"), "token strategy")
        XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
        XCTAssertEqual(request.headers["Accept"], "text/csv")
    }
}

// MARK: - Shared test helpers (file-private; mirror CursorProviderTests)

private func makeCursorJWT(sub: String = "google-oauth2|user", exp: Double = 9_999_999_999) -> String {
    let payload = #"{"sub":"\#(sub)","exp":\#(exp)}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var values: [String: String]
    init(values: [String: String] = [:]) { self.values = values }
    func queryValue(path: String, sql: String) throws -> String? {
        for (key, value) in values where sql.contains(key) { return value }
        return nil
    }
    func execute(path: String, sql: String) throws {}
}

// RoutingHTTPClient lives in TestSupport.swift (shared, records requests).

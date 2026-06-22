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

        // Combined cost + tokens, server-priced so no ⓘ (estimated: false).
        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 1.00, kind: .dollars), MetricValue(number: 100, kind: .count, label: "tokens")])
        XCTAssertEqual(values(lines, "Yesterday"), [MetricValue(number: 2.00, kind: .dollars), MetricValue(number: 200, kind: .count, label: "tokens")])
        // Last 30 Days sums every fetched day (the provider scopes the CSV to a 30-day window).
        XCTAssertEqual(values(lines, "Last 30 Days"), [MetricValue(number: 8.50, kind: .dollars), MetricValue(number: 1349, kind: .count, label: "tokens")])
    }

    func testZeroActivityReadsZeroDollarsAndTokens() {
        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: [], now: Date(), to: &lines)

        // The export fetched but had no rows: a real, measured zero, so every tile reads "$0.00 · 0
        // tokens" — not "0" and not "No data" (that's reserved for a failed export; see the provider test).
        let zero = [MetricValue(number: 0, kind: .dollars), MetricValue(number: 0, kind: .count, label: "tokens")]
        XCTAssertEqual(values(lines, "Today"), zero)
        XCTAssertEqual(values(lines, "Yesterday"), zero)
        XCTAssertEqual(values(lines, "Last 30 Days"), zero)
    }

    private func makeRow(date: Date, cost: Double, tokens: Int) -> CursorUsageCSVRow {
        CursorUsageCSVRow(
            date: date,
            model: "composer-1",
            maxMode: false,
            tokens: CursorTokenUsage(inputCacheWrite: 0, inputNoCacheWrite: tokens, cacheRead: 0, output: 0),
            imputedCostDollars: cost
        )
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}

// MARK: - Provider integration + render shape

@MainActor
final class CursorSpendProviderTests: XCTestCase {
    func testRefreshAppendsSpendTilesViaCookieSession() async {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        let todayStr = iso.string(from: now)
        let yesterdayStr = iso.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now)!)
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        \(todayStr),composer-1,No,0,0,0,1000000,Included
        \(yesterdayStr),composer-1,No,0,0,0,2000000,Included
        """

        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: spendRouter(accessToken: accessToken, csv: csv, csvStatus: 200)),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(textValue(snapshot.lines, "Today"), "$10.00")
        XCTAssertEqual(textValue(snapshot.lines, "Yesterday"), "$20.00")
        XCTAssertEqual(textValue(snapshot.lines, "Last 30 Days"), "$30.00")
    }

    func testCSVFailureLeavesSpendTilesAsNoData() async {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: spendRouter(accessToken: accessToken, csv: "", csvStatus: 401)),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()
        XCTAssertNil(textValue(snapshot.lines, "Today"))
        XCTAssertNil(textValue(snapshot.lines, "Yesterday"))
        XCTAssertNil(textValue(snapshot.lines, "Last 30 Days"))

        let descriptor = try! XCTUnwrap(provider.widgetDescriptors.first { $0.id == "cursor.today" })
        let defaults = isolatedDefaults("nodata")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider.provider], descriptors: provider.widgetDescriptors),
            providers: [provider],
            cache: isolatedCache(defaults),
            defaults: defaults
        )
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertFalse(data.hasData)
        XCTAssertEqual(data.valueText, WidgetData.noDataHeadline)
    }

    func testSpendTileRendersCombinedCostAndTokensWithNoEstimateIcon() async {
        let cursor = CursorProvider()
        let descriptor = try! XCTUnwrap(cursor.widgetDescriptors.first { $0.id == "cursor.today" })

        // The combined tile joins the dollar and the labeled token count. A no-usage day is a real zero,
        // so it reads "$0.00 · 0 tokens" (not "No data" — that's only for a failed export).
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
            // Cursor spend is server-priced, so the combined tile carries no estimate ⓘ (that's reserved
            // for the ccusage/Grok tiles whose dollars are locally estimated).
            XCTAssertNil(remaining.infoNote)
            // Unbounded: identical under both meter styles.
            XCTAssertEqual(used.valueText, remaining.valueText)
            XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
            XCTAssertEqual(used.infoNote, remaining.infoNote)
        }
    }

    // MARK: helpers

    private func spendRouter(accessToken: String, csv: String, csvStatus: Int) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("export-usage-events-csv") {
                XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
                XCTAssertEqual(request.headers["Accept"], "text/csv")
                return HTTPResponse(statusCode: csvStatus, headers: [:], body: Data(csv.utf8))
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
    }

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

// MARK: - Shared test helpers (file-private; mirror CursorProviderTests)

private func textValue(_ lines: [MetricLine], _ label: String) -> String? {
    guard let line = lines.first(where: { $0.label == label }) else { return nil }
    if case .text(_, let value, _, _) = line { return value }
    // Cursor spend is now a `.values` row carrying a single dollar value; render it in full.
    if case .values(_, let values, _, _) = line, let dollars = values.first(where: { $0.kind == .dollars }) {
        return MetricFormatter.number(dollars.number, kind: .dollars, style: .full)
    }
    return nil
}

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

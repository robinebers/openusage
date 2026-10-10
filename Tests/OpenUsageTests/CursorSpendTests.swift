import XCTest
@testable import OpenUsage

// MARK: - Range aggregation

final class CursorSpendRangeTests: XCTestCase {
    func testMuseSpark13EffortsCountTowardSpendAndShareOneBreakdownWithoutWarnings() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let models = [
            "muse-spark-1.3", "muse-spark-1.3-minimal", "muse-spark-1.3-low",
            "muse-spark-1.3-medium", "muse-spark-1.3-high", "muse-spark-1.3-xhigh",
            "muse-spark-1.3-extra-high", "muse-spark-1.3-max"
        ]
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        let rows = models.map { model in
            makePricedRow(date: now, model: model, tokens: tokens, pricing: TestPricing.bundled)
        }
        // $1.25 input + $1.25 cache writes + $0.15 cache reads + $4.25 output.
        for row in rows {
            XCTAssertEqual(try XCTUnwrap(row.imputedCostDollars), 6.9, accuracy: 1e-9, row.model)
        }

        var lines: [MetricLine] = []
        _ = CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)
        for label in ["Today", "Last 30 Days"] {
            XCTAssertEqual(values(lines, label), [
                MetricValue(number: 55.2, kind: .dollars, estimated: true),
                MetricValue(number: 32_000_000, kind: .count, label: "tokens")
            ])
            XCTAssertEqual(unknown(lines, label), [])
            let breakdown = try XCTUnwrap(modelBreakdown(lines, label))
            XCTAssertEqual(breakdown.models.map(\.model), ["muse-spark-1.3"])
            XCTAssertEqual(breakdown.models.first?.totalTokens, 32_000_000)
            XCTAssertEqual(breakdown.models.first?.costUSD, 55.2)
            XCTAssertEqual(Set(breakdown.models.first?.variants?.map(\.model) ?? []), Set(models))
        }
    }

    func testGemini38FlashHighUsageCountsTowardSpendWithoutUnknownWarning() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        let row = makePricedRow(date: now, model: "gemini-3.8-flash-high", tokens: tokens, pricing: TestPricing.bundled)
        // $0.75 input + $0.75 cache writes + $0.075 cache reads + $3.75 output.
        XCTAssertEqual(try XCTUnwrap(row.imputedCostDollars), 5.325, accuracy: 1e-9)

        var lines: [MetricLine] = []
        _ = CursorUsageMapper.appendSpendLines(rows: [row], now: now, pricing: TestPricing.bundled, to: &lines)

        for label in ["Today", "Last 30 Days"] {
            XCTAssertEqual(values(lines, label), [
                MetricValue(number: 5.33, kind: .dollars, estimated: true),
                MetricValue(number: 4_000_000, kind: .count, label: "tokens")
            ])
            XCTAssertEqual(unknown(lines, label), [])
        }
    }

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
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        // Tokens come from Cursor; dollars are calculated locally and marked as estimated.
        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 1.00, kind: .dollars, estimated: true), MetricValue(number: 100, kind: .count, label: "tokens")])
        XCTAssertEqual(values(lines, "Yesterday"), [MetricValue(number: 2.00, kind: .dollars, estimated: true), MetricValue(number: 200, kind: .count, label: "tokens")])
        // Last 30 Days sums every fetched day (the provider scopes history to a 30-day window).
        XCTAssertEqual(values(lines, "Last 30 Days"), [MetricValue(number: 8.50, kind: .dollars, estimated: true), MetricValue(number: 1349, kind: .count, label: "tokens")])

        guard case .chart(let label, let points, let note) = lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("expected a Usage Trend chart line")
        }
        XCTAssertEqual(label, "Usage Trend")
        // Cursor's tokens come from its server usage history, so the note names that source, not local logs.
        XCTAssertEqual(note, "From your Cursor usage history")
        XCTAssertEqual(points.count, 31, "one bar per calendar day across the 31-day window")
        XCTAssertEqual(points.last?.value, 100, "today's tokens land on the last bar")
        XCTAssertEqual(points[29].value, 200, "yesterday's tokens land on the second-to-last bar")
    }

    func testEmptyHistoryLeavesSpendTilesAndUsageTrendUnbacked() {
        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: [], now: Date(), pricing: TestPricing.bundled, to: &lines)
        XCTAssertTrue(lines.isEmpty)
    }

    func testUnknownModelsAttachToTheRightPeriods() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cal = Calendar.current
        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100, model: "composer-1"),                                  // priced, today
            makeRow(date: now, cost: nil, tokens: 50, model: "totally-unknown-model-xyz"),                      // unknown, today
            makeRow(date: cal.date(byAdding: .day, value: -1, to: now)!, cost: 2.00, tokens: 200, model: "composer-1"), // priced, yesterday
            makeRow(date: cal.date(byAdding: .day, value: -3, to: now)!, cost: nil, tokens: 80, model: "another-unknown-abc") // unknown, last30 only
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

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
            makeRow(date: now, cost: nil, tokens: 0, model: "totally-unknown-model-xyz")
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        XCTAssertNotNil(values(lines, "Today"), "the priced row keeps the tile present")
        XCTAssertEqual(unknown(lines, "Today"), [])
        XCTAssertEqual(unknown(lines, "Last 30 Days"), [])
    }

    func testAppendSpendLinesAttachesModelBreakdown() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            makeRow(date: now, cost: 1.004, tokens: 100, model: "composer-1"),
            makeRow(date: now, cost: 2.006, tokens: 200, model: "gpt-5.5"),
            makeRow(date: now, cost: nil, tokens: 300, model: "unpriced-cursor-model")
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        // The unpriced row is excluded from the tile's tokens and the breakdown alike — it surfaces
        // only through the unknown-model warning.
        XCTAssertEqual(values(lines, "Today"),
                       [MetricValue(number: 3.01, kind: .dollars, estimated: true), MetricValue(number: 300, kind: .count, label: "tokens")])
        XCTAssertEqual(unknown(lines, "Today"), ["unpriced-cursor-model"])
        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.sourceNote, "From your Cursor usage history")
        XCTAssertEqual(breakdown.models.map(\.model), ["gpt-5.5", "composer-1"])
        XCTAssertEqual(breakdown.models.map(\.totalTokens), [200, 100])
        XCTAssertEqual(breakdown.models[0].costUSD, 2.01, "model cost rounds once at the displayed aggregate")
    }

    func testModelBreakdownGroupsThinkingEffortSlugsIntoFamilies() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Cursor reports one slug per thinking-effort/fast combination; the panel row must group them
        // under the canonical base model (via the supplement alias rules, with `-fast` folded into its
        // base) and keep the raw slugs as the tooltip's per-effort variants.
        let rows = [
            makeRow(date: now, cost: 3.00, tokens: 300, model: "claude-opus-4-8-thinking-max"),
            makeRow(date: now, cost: 1.00, tokens: 100, model: "claude-opus-4-8-thinking-high"),
            makeRow(date: now, cost: 2.00, tokens: 200, model: "gpt-5.5-extra-high-fast"),
            makeRow(date: now, cost: 0.50, tokens: 50, model: "gpt-5.5")
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.models.map(\.model), ["claude-opus-4-8", "gpt-5.5"])

        let opus = try XCTUnwrap(breakdown.models.first { $0.model == "claude-opus-4-8" })
        XCTAssertEqual(opus.totalTokens, 400)
        XCTAssertEqual(opus.costUSD, 4.00)
        XCTAssertEqual(opus.variants?.map(\.model), ["claude-opus-4-8-thinking-max", "claude-opus-4-8-thinking-high"],
                       "variants keep the raw slugs, largest spend first")
        XCTAssertEqual(opus.variants?.map(\.costUSD), [3.00, 1.00])

        let gpt = try XCTUnwrap(breakdown.models.first { $0.model == "gpt-5.5" })
        XCTAssertEqual(gpt.variants?.map(\.model), ["gpt-5.5-extra-high-fast", "gpt-5.5"],
                       "a -fast canonical folds into its base family")
    }

    func testUnpricedOnlyDayLeavesTilesUnbacked() {
        // A day whose every row is unpriceable has nothing coherent to display: no tiles, no trend —
        // the excluded usage exists only in `unknownModelsByDay` (which needs a rendered tile to show
        // its triangle; here there is none, matching "No data").
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            makeRow(date: now, cost: nil, tokens: 100, model: "totally-unknown-model-xyz")
        ]

        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        XCTAssertNil(values(lines, "Today"))
        XCTAssertNil(values(lines, "Last 30 Days"))
        XCTAssertNil(lines.first(where: { $0.label == "Usage Trend" }))
    }

    private func modelBreakdown(_ lines: [MetricLine], _ label: String) -> ModelUsageBreakdown? {
        guard case .values(_, _, _, _, _, let breakdown) = lines.first(where: { $0.label == label }) else { return nil }
        return breakdown
    }

    private func unknown(_ lines: [MetricLine], _ label: String) -> [String]? {
        guard case .values(_, _, _, _, let unknownModels, _) = lines.first(where: { $0.label == label }) else { return nil }
        return unknownModels
    }

    /// `cost: nil` models a row no pricing source could price (the unknown-model case).
    private func makeRow(date: Date, cost: Double?, tokens: Int, model: String = "composer-1") -> CursorUsageRow {
        CursorUsageRow(
            date: date,
            model: model,
            tokens: TokenBreakdown(input: tokens),
            imputedCostDollars: cost
        )
    }

    private func makePricedRow(
        date: Date,
        model: String,
        tokens: TokenBreakdown,
        pricing: ModelPricing
    ) -> CursorUsageRow {
        CursorUsageRow(
            date: date,
            model: model,
            tokens: tokens,
            imputedCostDollars: pricing.estimatedCostDollars(
                model: model,
                tokens: tokens,
                applyLongContextRates: false
            )
        )
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}

// MARK: - Provider integration + render shape

@MainActor
final class CursorSpendProviderTests: XCTestCase {
    func testSpendTileRendersCombinedCostAndTokensWithValueTooltip() async {
        let cursor = CursorProvider()
        let descriptor = try! XCTUnwrap(cursor.widgetDescriptors.first { $0.id == "cursor.today" })

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
                        MetricValue(number: dollars, kind: .dollars, estimated: true),
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
            XCTAssertEqual(remaining.infoNote, WidgetData.localEstimateNote)
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

// makeCursorJWT, KeyValueSQLite, and RoutingHTTPClient live in TestSupport.swift.

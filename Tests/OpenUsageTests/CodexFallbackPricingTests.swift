import XCTest
@testable import OpenUsage

final class CodexFallbackPricingTests: XCTestCase {
    private let reference = "gpt-5.6-sol"

    private func pricing() -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(
                pricing: [reference: ModelRates(
                    inputPerMillion: 5, outputPerMillion: 30,
                    cacheWritePerMillion: 5, cacheReadPerMillion: 0.5,
                    fastMultiplier: 2.5
                )],
                fallbackModels: ["codex": [reference]]
            ),
            primary: PricingCatalog(entries: ["known-model": ModelRates(
                inputPerMillion: 1, outputPerMillion: 2,
                cacheWritePerMillion: 1, cacheReadPerMillion: 0.1
            )]),
            secondary: PricingCatalog()
        )
    }

    private func event(
        model: String = "unlisted-model-a", input: Int = 1_000,
        cached: Int = 400, output: Int = 100, fast: Bool = false
    ) -> CodexLogUsageScanner.Event {
        .init(timestamp: Date(timeIntervalSince1970: 1_780_000_000), model: model,
              input: input, cached: cached, output: output, reasoning: 0,
              total: input + output, isFast: fast)
    }

    func testNoneExcludesUnpricedUsageAndKeepsWarnings() {
        let result = CodexLogUsageScanner.aggregate(events: [event()], since: .distantPast, pricing: pricing())
        XCTAssertTrue(result.series.daily.isEmpty)
        XCTAssertEqual(Set(result.unknownModelsByDay.values.flatMap { $0 }), ["unlisted-model-a"])
        XCTAssertNil(result.fallbackPricingModelsByDay)
    }

    func testFallbackPricesTokensAndPreservesModelAttributionAndWarning() throws {
        let result = CodexLogUsageScanner.aggregate(
            events: [event()], since: .distantPast, pricing: pricing(), fallbackModel: reference
        )
        let day = try XCTUnwrap(result.series.daily.first)
        XCTAssertEqual(day.totalTokens, 1_100)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.0062, accuracy: 0.000_001)
        XCTAssertEqual(result.modelUsage?.daily.first?.models.first?.model, "unlisted-model-a")
        XCTAssertEqual(Set(result.unknownModelsByDay.values.flatMap { $0 }), ["unlisted-model-a"])
        XCTAssertEqual(result.fallbackPricingModelsByDay, [day.date: [reference]])
    }

    func testFallbackWarningReachesTheSpendTileTooltip() throws {
        let usage = event(input: 1_000_000, cached: 400_000, output: 100_000)
        let scan = CodexLogUsageScanner.aggregate(
            events: [usage], since: .distantPast, pricing: pricing(), fallbackModel: reference
        )
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.series, to: &lines, now: usage.timestamp,
            unknownModelsByDay: scan.unknownModelsByDay, modelUsage: scan.modelUsage
        )

        for label in ["Today", "Last 30 Days"] {
            guard case .values(_, let values, _, _, let unknownModels, _) = lines.first(where: { $0.label == label }) else {
                return XCTFail("Missing spend row")
            }
            XCTAssertGreaterThan(try XCTUnwrap(values.first(where: { $0.kind == .dollars })?.number), 0)
            var tile = WidgetData(title: label, icon: .providerMark("codex"), kind: .dollars, used: 0)
            tile.values = values
            tile.hasData = true
            tile.unknownModels = unknownModels
            XCTAssertTrue(tile.hasUnknownModels)
            XCTAssertEqual(tile.unknownModelTooltip, "Unknown model found\n- unlisted-model-a")
        }
    }

    func testKnownPricesAndExplicitPricingModelsWin() {
        var mapped = event(model: "review-model")
        mapped.pricingModel = "known-model"
        let events = [event(model: "known-model"), mapped]
        let normal = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: pricing())
        let fallback = CodexLogUsageScanner.aggregate(
            events: events, since: .distantPast, pricing: pricing(), fallbackModel: reference
        )
        XCTAssertEqual(fallback.series, normal.series)
        XCTAssertEqual(fallback.modelUsage, normal.modelUsage)
        XCTAssertTrue(fallback.unknownModelsByDay.isEmpty)
        XCTAssertNil(fallback.fallbackPricingModelsByDay)
    }

    func testFallbackUsesReferenceContextAndPriorityRulesExactlyOnce() throws {
        let cases: [(input: Int, cached: Int, output: Int, fast: Bool, expected: Double)] = [
            (272_000, 72_000, 1_000, false, 1.066),
            (300_000, 100_000, 10_000, false, 2.55),
            (300_000, 100_000, 10_000, true, 5.1),
            (1_000, 400, 100, true, 0.0124)
        ]
        for entry in cases {
            let result = CodexLogUsageScanner.aggregate(
                events: [event(input: entry.input, cached: entry.cached, output: entry.output, fast: entry.fast)],
                since: .distantPast, pricing: pricing(), fallbackModel: reference
            )
            XCTAssertEqual(try XCTUnwrap(result.series.daily.first?.costUSD), entry.expected, accuracy: 0.000_001)
        }
        let fastSuffix = CodexLogUsageScanner.aggregate(
            events: [event(model: "unlisted-model-a-fast", fast: true)],
            since: .distantPast, pricing: pricing(), fallbackModel: reference
        )
        XCTAssertEqual(try XCTUnwrap(fastSuffix.series.daily.first?.costUSD), 0.0124, accuracy: 0.000_001)
    }

    func testFallbackPreservesDeduplicationAndSkipsBlankModels() {
        let result = CodexLogUsageScanner.aggregate(
            events: [event(), event(), event(model: "unlisted-model-b"), event(model: " \n")],
            since: .distantPast, pricing: pricing(), fallbackModel: reference
        )
        XCTAssertEqual(result.series.daily.first?.totalTokens, 2_200)
        XCTAssertEqual(result.modelUsage?.daily.first?.models.count, 2)
    }

    func testUnavailableReferenceDoesNotTurnMissingPricesIntoZero() {
        let result = CodexLogUsageScanner.aggregate(
            events: [event()], since: .distantPast, pricing: pricing(), fallbackModel: "unavailable-model"
        )
        XCTAssertTrue(result.series.daily.isEmpty)
        XCTAssertFalse(result.unknownModelsByDay.isEmpty)
        XCTAssertNil(result.fallbackPricingModelsByDay)
    }

    func testChangingPreferenceRepricesCachedEventsAndCanReturnToNone() async throws {
        let home = try CodexLogFixture.makeHome(files: ["sessions/rollout.jsonl": [
            CodexLogFixture.turnContext(timestamp: "2026-08-20T10:00:00Z", model: "unlisted-model-a"),
            CodexLogFixture.tokenCount(timestamp: "2026-08-20T10:01:00Z", last: CodexLogFixture.usage(input: 1_000, output: 100))
        ].joined(separator: "\n")])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CodexLogFixture.scanner(home: home)
        let now = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-08-20T12:00:00Z"))
        let none = await scanner.scan(now: now, pricing: pricing())
        let estimated = await scanner.scan(now: now, pricing: pricing(), fallbackModel: reference)
        let noneAgain = await scanner.scan(now: now, pricing: pricing())
        XCTAssertTrue(try XCTUnwrap(none).series.daily.isEmpty)
        XCTAssertEqual(estimated?.series.daily.first?.totalTokens, 1_100)
        XCTAssertEqual(estimated?.unknownModelsByDay, none?.unknownModelsByDay)
        XCTAssertEqual(noneAgain?.series, none?.series)
        XCTAssertNil(noneAgain?.fallbackPricingModelsByDay)
    }

    func testPreferenceDefaultsToNoneAndPersistsAnExplicitChoice() throws {
        let suite = "fallback-setting-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(CodexFallbackModelSetting.current(defaults: defaults))
        defaults.set(reference, forKey: CodexFallbackModelSetting.key)
        XCTAssertEqual(CodexFallbackModelSetting.current(defaults: defaults), reference)
        defaults.set(CodexFallbackModelSetting.none, forKey: CodexFallbackModelSetting.key)
        XCTAssertNil(CodexFallbackModelSetting.current(defaults: defaults))
    }

    func testRefreshTracksChoiceAndAvailabilityWithoutRepeatingUnchangedOptions() {
        var state = CodexFallbackPricingRefreshState()
        let options = pricing().fallbackOptions(for: "codex")
        XCTAssertFalse(state.update(model: "", options: []))
        XCTAssertFalse(state.update(model: "", options: options))
        XCTAssertTrue(state.update(model: reference, options: options))
        XCTAssertFalse(state.update(model: reference, options: options.reversed()))
        XCTAssertTrue(state.update(model: reference, options: []), "losing pricing must clear stale estimates")
        XCTAssertFalse(state.update(model: reference, options: []))
        XCTAssertTrue(state.update(model: reference, options: options), "restored pricing must restore estimates")
        XCTAssertTrue(state.update(model: "unavailable-model", options: options))
        XCTAssertTrue(state.update(model: "", options: options))
        XCTAssertFalse(state.update(model: "", options: []))
    }

    func testOpeningSettingsRecalculatesASavedChoiceEvenIfAlreadyUnavailable() {
        for options in [[], pricing().fallbackOptions(for: "codex")] {
            var state = CodexFallbackPricingRefreshState()
            XCTAssertTrue(state.update(model: reference, options: options))
            XCTAssertFalse(state.update(model: reference, options: options))
        }
    }

    func testFallbackSourceNotesOnlyDescribeTheirOwnPeriod() throws {
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 12)))
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
        var known = event(model: "known-model")
        known.timestamp = now
        var unpriced = event()
        unpriced.timestamp = yesterday
        let scan = CodexLogUsageScanner.aggregate(
            events: [known, unpriced], since: .distantPast, pricing: pricing(), fallbackModel: reference
        )
        XCTAssertEqual(scan.fallbackPricingModelsByDay, [DailyUsageAccumulator.dayKey(from: yesterday): [reference]])
        let history = ProviderUsageHistory(
            series: scan.series, modelUsage: scan.modelUsage, unknownModelsByDay: scan.unknownModelsByDay,
            fallbackPricingModelsByDay: scan.fallbackPricingModelsByDay
        )
        let local = ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [])
        let descriptor = UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")
        for combined in [false, true] {
            let rendered = UsageHistorySnapshotRenderer.render(
                local: local, history: history, descriptor: descriptor, now: now, combined: combined
            )
            let baseNote = combined ? "Across your Macs · logs" : "logs"
            for label in ["Today", "Yesterday", "Last 30 Days"] {
                guard case .values(_, _, _, _, _, let breakdown) = rendered.lines.first(where: { $0.label == label }) else {
                    return XCTFail("Missing spend row")
                }
                XCTAssertEqual(breakdown?.sourceNote, label == "Today" ? baseNote : baseNote + " · Fallback estimates: GPT 5.6 Sol")
            }
            guard case .chart(_, _, let note) = rendered.lines.first(where: { $0.label == "Usage Trend" }) else {
                return XCTFail("Missing usage trend")
            }
            XCTAssertEqual(note, baseNote + " · Fallback estimates: GPT 5.6 Sol")
        }
    }

    func testMergedScansKeepFallbackProvenance() throws {
        let scan = CodexLogUsageScanner.aggregate(
            events: [event()], since: .distantPast, pricing: pricing(), fallbackModel: reference
        )
        let day = try XCTUnwrap(scan.series.daily.first?.date)
        var other = DailyUsageAccumulator()
        other.add(day: day, tokens: 20, cost: 1, model: "unlisted-model-b", fallbackPricingModel: "gpt-5.5")
        other.add(day: "2026-01-01", tokens: 10, cost: 1, model: "unlisted-model-b", fallbackPricingModel: "gpt-5.5")
        let merged = try XCTUnwrap(DailyUsageAccumulator.merged([scan, other.build(), nil]))
        XCTAssertEqual(merged.fallbackPricingModelsByDay, [day: [reference, "gpt-5.5"], "2026-01-01": ["gpt-5.5"]])
        XCTAssertEqual(merged.unknownModelsByDay, scan.unknownModelsByDay)
    }
}

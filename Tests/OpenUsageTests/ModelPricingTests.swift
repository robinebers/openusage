import XCTest
@testable import OpenUsage

/// Resolution and cost math for the pricing engine, against small fixture catalogs.
final class ModelPricingTests: XCTestCase {
    private func makePricing(
        supplementJSON: String? = nil,
        primary: [String: ModelRates] = [:],
        secondary: [String: ModelRates] = [:]
    ) throws -> ModelPricing {
        let supplement: PricingSupplement
        if let supplementJSON {
            supplement = try PricingSupplement.decode(from: Data(supplementJSON.utf8))
        } else {
            supplement = PricingSupplement()
        }
        return ModelPricing(
            supplement: supplement,
            primary: PricingCatalog(entries: primary),
            secondary: PricingCatalog(entries: secondary)
        )
    }

    private func rates(
        _ input: Double, _ output: Double, cacheWrite: Double? = nil, cacheRead: Double? = nil,
        fast: Double = 1
    ) -> ModelRates {
        ModelRates(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheWritePerMillion: cacheWrite ?? input,
            cacheReadPerMillion: cacheRead ?? input * 0.1,
            fastMultiplier: fast
        )
    }

    // MARK: - Resolution

    func testExactMatchWins() throws {
        let pricing = try makePricing(primary: ["gpt-5.5": rates(5, 30)])
        XCTAssertEqual(pricing.resolve(model: "gpt-5.5")?.inputPerMillion, 5)
    }

    func testDateSuffixFuzzyMatch() throws {
        let pricing = try makePricing(primary: ["claude-sonnet-4-20250514": rates(3, 15)])
        XCTAssertEqual(pricing.resolve(model: "claude-sonnet-4")?.inputPerMillion, 3)
    }

    func testModelWithDateSuffixResolvesUndatedKey() throws {
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": rates(3, 15)])
        XCTAssertEqual(pricing.resolve(model: "claude-sonnet-4-5-20250929")?.inputPerMillion, 3)
    }

    func testNumericVersionsDoNotConflate() throws {
        // claude-sonnet-4 must not price as claude-sonnet-4-5 (or vice versa).
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": rates(3, 15)])
        XCTAssertNil(pricing.resolve(model: "claude-sonnet-4"))
        let reverse = try makePricing(primary: ["claude-sonnet-4": rates(1, 2)])
        XCTAssertNil(reverse.resolve(model: "claude-sonnet-4-5"))
    }

    func testProviderPrefixFuzzyMatch() throws {
        let pricing = try makePricing(primary: ["xai/grok-4.3": rates(1.25, 2.5)])
        XCTAssertEqual(pricing.resolve(model: "grok-4.3")?.inputPerMillion, 1.25)
    }

    func testSeparatorNormalizationMatch() throws {
        // Log slug grok-4-3 (dashes) matches catalog key xai/grok-4.3 (dot).
        let pricing = try makePricing(primary: ["xai/grok-4.3": rates(1.25, 2.5)])
        XCTAssertEqual(pricing.resolve(model: "grok-4-3")?.inputPerMillion, 1.25)
    }

    func testLongestKeyPreferred() throws {
        let pricing = try makePricing(primary: [
            "gemini-3-pro": rates(1, 2),
            "gemini/gemini-3-pro-preview": rates(2, 12)
        ])
        XCTAssertEqual(pricing.resolve(model: "gemini-3-pro-preview")?.inputPerMillion, 2)
    }

    func testSecondaryCatalogFillsGaps() throws {
        let pricing = try makePricing(
            primary: ["gpt-5.5": rates(5, 30)],
            secondary: ["grok-build-0.1": rates(1, 2)]
        )
        XCTAssertEqual(pricing.resolve(model: "grok-build-0.1")?.inputPerMillion, 1)
    }

    func testUnknownModelReturnsNil() throws {
        let pricing = try makePricing(primary: ["gpt-5.5": rates(5, 30)])
        XCTAssertNil(pricing.resolve(model: "made-up-model-9000"))
    }

    // MARK: - Supplement precedence, aliases, fast multipliers

    func testSupplementPricingBeatsCatalogs() throws {
        let supplement = """
        {"pricing": {"auto": {"input_per_million": 1.25, "output_per_million": 6.0, "cache_read_per_million": 0.25}}, "alias_rules": []}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["auto": rates(99, 99)])
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1.25)
        XCTAssertEqual(pricing.resolve(model: "auto")?.cacheWritePerMillion, 1.25, "cache write defaults to input")
    }

    func testAliasRuleRewritesSlug() throws {
        let supplement = """
        {"pricing": {}, "alias_rules": [
            {"pattern": "^claude-4\\\\.5-sonnet(?:-thinking)?$", "canonical": "claude-sonnet-4-5"}
        ]}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["claude-sonnet-4-5": rates(3, 15)])
        XCTAssertEqual(pricing.resolve(model: "claude-4.5-sonnet-thinking")?.inputPerMillion, 3)
    }

    func testAliasMissFallsBackToRawName() throws {
        let supplement = """
        {"pricing": {}, "alias_rules": [{"pattern": "^gpt-x$", "canonical": "key-not-anywhere"}]}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["gpt-x": rates(1, 2)])
        XCTAssertEqual(pricing.resolve(model: "gpt-x")?.inputPerMillion, 1)
    }

    func testFastSuffixUsesSupplementMultiplier() throws {
        let supplement = """
        {"pricing": {}, "fast_multipliers": {"gpt-5.5": 2.5}, "alias_rules": []}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["gpt-5.5": rates(5, 30, cacheRead: 0.5)])
        let fast = pricing.resolve(model: "gpt-5.5-fast")
        XCTAssertEqual(fast?.inputPerMillion, 12.5)
        XCTAssertEqual(fast?.outputPerMillion, 75)
        XCTAssertEqual(fast?.cacheReadPerMillion, 1.25)
    }

    func testFastSuffixUsesEntryMultiplier() throws {
        let pricing = try makePricing(primary: ["claude-opus-4-6": rates(5, 25, fast: 6)])
        let fast = pricing.resolve(model: "claude-opus-4-6-fast")
        XCTAssertEqual(fast?.inputPerMillion, 30)
        XCTAssertEqual(fast?.fastMultiplier, 1, "multiplier folded into the scaled rates")
    }

    func testFastSuffixWithoutMultiplierReturnsNil() throws {
        let pricing = try makePricing(primary: ["gpt-9": rates(1, 2)])
        XCTAssertNil(pricing.resolve(model: "gpt-9-fast"))
    }

    func testFastSuffixWithoutMultiplierUsesSecondaryExactEntry() throws {
        let pricing = try makePricing(
            primary: ["gpt-9": rates(1, 2)],
            secondary: ["gpt-9-fast": rates(2.5, 5)]
        )
        XCTAssertEqual(pricing.resolve(model: "gpt-9-fast")?.inputPerMillion, 2.5)
    }

    func testDatedBaseKeyStillFindsFastMultiplier() throws {
        let supplement = """
        {"pricing": {}, "fast_multipliers": {"gpt-5.5": 2.5}, "alias_rules": []}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["gpt-5.5-20260423": rates(5, 30)])
        XCTAssertEqual(pricing.resolve(model: "gpt-5.5-fast")?.inputPerMillion, 12.5)
    }

    // MARK: - Cost math

    func testCostUsesAllTokenBuckets() throws {
        let entry = ModelRates(
            inputPerMillion: 3, outputPerMillion: 15,
            cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3
        )
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        // input 3 + cacheWrite5m 3.75 + cacheWrite1h (3x2=6) + cacheRead 0.3 + output 15 = 28.05
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, 28.05, accuracy: 0.0001)
    }

    func testCostAbove200kUsesHigherRateForWholeRequest() throws {
        var entry = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3)
        entry.inputAbove200kPerMillion = 6
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 300_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, 1.8, accuracy: 0.0001)
    }

    func testCombinedPromptBucketsSelectLongContextRatesForEveryBucket() throws {
        var entry = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3)
        entry.inputAbove200kPerMillion = 6
        entry.outputAbove200kPerMillion = 22.5
        entry.cacheWriteAbove200kPerMillion = 7.5
        entry.cacheReadAbove200kPerMillion = 0.6
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 100_000, cacheWrite5m: 60_000, cacheRead: 50_000, output: 20_000)

        // The 210k prompt selects the higher tier for input, cache, and output alike.
        let expected = 0.6 + 0.45 + 0.03 + 0.45
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, expected, accuracy: 0.0001)
    }

    func testLargeOutputAloneDoesNotSelectLongContextRates() throws {
        var entry = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3)
        entry.inputAbove200kPerMillion = 6
        entry.outputAbove200kPerMillion = 22.5
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 10_000, output: 300_000)

        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, 4.53, accuracy: 0.0001)
    }

    func testExactly200kPromptKeepsBaseRates() throws {
        var entry = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3)
        entry.inputAbove200kPerMillion = 6
        entry.outputAbove200kPerMillion = 22.5
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 200_000, output: 10_000)

        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, 0.75, accuracy: 0.0001)
    }

    func testCostWithoutTierRatesUsesBaseRateThroughout() throws {
        let pricing = try makePricing(primary: ["gpt-5.5": rates(5, 30)])
        let tokens = TokenBreakdown(input: 300_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "gpt-5.5", tokens: tokens)!, 1.5, accuracy: 0.0001)
    }

    func testFastSpeedAppliesEntryMultiplier() throws {
        let pricing = try makePricing(primary: ["claude-opus-4-6": rates(5, 25, fast: 6)])
        var tokens = TokenBreakdown(input: 1_000_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-opus-4-6", tokens: tokens)!, 5, accuracy: 0.0001)
        tokens.isFast = true
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-opus-4-6", tokens: tokens)!, 30, accuracy: 0.0001)
    }

    func testUnknownModelCostIsNil() throws {
        let pricing = try makePricing()
        XCTAssertNil(pricing.estimatedCostDollars(model: "mystery", tokens: TokenBreakdown(input: 100)))
    }
}

import XCTest
@testable import OpenUsage

/// Guards the shipped pricing resources: the bundled supplement and snapshots must load, and every
/// alias canonical must resolve against them — so a LiteLLM/models.dev key rename or a supplement
/// typo fails CI instead of silently pricing models at $0.
final class PricingBundledResourceTests: XCTestCase {
    private static let pricing = TestPricing.bundled

    func testBundledResourcesLoadAndAreNonTrivial() {
        let pricing = Self.pricing
        XCTAssertGreaterThan(pricing.primary.entries.count, 500, "LiteLLM snapshot suspiciously small")
        XCTAssertGreaterThan(pricing.secondary.entries.count, 500, "models.dev snapshot suspiciously small")
        XCTAssertFalse(pricing.supplement.pricing.isEmpty)
        XCTAssertFalse(pricing.supplement.aliasRules.isEmpty)
    }

    func testEveryAliasCanonicalResolves() {
        let pricing = Self.pricing
        for rule in pricing.supplement.aliasRules {
            XCTAssertNotNil(
                pricing.resolve(model: rule.canonical),
                "alias canonical '\(rule.canonical)' resolves against no pricing source"
            )
        }
    }

    func testEveryFastMultiplierBaseResolves() {
        let pricing = Self.pricing
        for base in Self.pricing.supplement.fastMultipliers.keys {
            XCTAssertNotNil(pricing.resolve(model: base), "fast-multiplier base '\(base)' resolves nowhere")
        }
    }

    /// Spot-check Cursor CSV slugs end to end against known rates (the old manifest's assertions,
    /// now against live catalogs — update the constants if the providers themselves reprice).
    func testKnownCursorSlugsPriceCorrectly() {
        let pricing = Self.pricing
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1.25)
        XCTAssertEqual(pricing.resolve(model: "claude-4.5-sonnet-thinking")?.inputPerMillion, 3)
        XCTAssertEqual(pricing.resolve(model: "claude-4.6-opus-max-thinking")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "claude-4.6-opus-max-thinking-fast")?.inputPerMillion, 30)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.5-xhigh-fast")?.inputPerMillion, 12.5)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-sol-ultra")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-sol-ultra-fast")?.inputPerMillion, 10)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-terra-high")?.inputPerMillion, 2)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-terra-high-fast")?.inputPerMillion, 4)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-luna")?.inputPerMillion, 0.2)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-luna-fast")?.inputPerMillion, 0.4)
        XCTAssertEqual(pricing.resolve(model: "gemini-3.6-flash-high")?.inputPerMillion, 1.5)
        XCTAssertEqual(pricing.resolve(model: "gemini-3.7-flash-high")?.inputPerMillion, 0.75)
        XCTAssertEqual(pricing.resolve(model: "gemini-3.7-flash-high")?.outputPerMillion, 3.75)
        XCTAssertEqual(pricing.resolve(model: "grok-4-20-thinking")?.inputPerMillion, 2)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5")?.inputPerMillion, 2)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-fast-high")?.inputPerMillion, 4)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-high-fast")?.inputPerMillion, 4)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.5-high-fast")?.inputPerMillion, 4)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.6-high")?.inputPerMillion, 2)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.6-high-fast")?.inputPerMillion, 4)
        XCTAssertEqual(pricing.resolve(model: "grok-4-6-xhigh")?.inputPerMillion, 2)
        XCTAssertEqual(pricing.resolve(model: "grok-4-6-xhigh-fast")?.inputPerMillion, 4)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2p5")?.inputPerMillion, 0.6)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2.7-code")?.inputPerMillion, 0.95)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2p7")?.inputPerMillion, 0.95)
        XCTAssertEqual(pricing.resolve(model: "kimi-k3-max")?.inputPerMillion, 3)
        XCTAssertEqual(pricing.resolve(model: "claude-4.7-opus-high-thinking")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "claude-4.7-opus-max-thinking-fast")?.inputPerMillion, 30)
        XCTAssertEqual(pricing.resolve(model: "glm-5.2-max")?.inputPerMillion, 1.4)
        XCTAssertEqual(pricing.resolve(model: "github_bugbot")?.outputPerMillion, 30)
        XCTAssertEqual(pricing.resolve(model: "Premium (GPT-5.3-Codex)")?.inputPerMillion, 1.75)
    }

    /// Raw model ids as they appear in Claude/Codex/Grok logs (no alias rewriting).
    func testKnownLogModelIDsPriceCorrectly() {
        let pricing = Self.pricing
        XCTAssertEqual(pricing.resolve(model: "claude-sonnet-4-5-20250929")?.inputPerMillion, 3)
        XCTAssertEqual(pricing.resolve(model: "claude-opus-4-1-20250805")?.inputPerMillion, 15)
        XCTAssertNotNil(pricing.resolve(model: "gpt-5.1-codex"))
        XCTAssertEqual(pricing.resolve(model: "gpt-daybreak-blue-latest"), pricing.resolve(model: "gpt-5.6-sol"))
        XCTAssertEqual(pricing.resolve(model: "daybreak-blue-latest"), pricing.resolve(model: "gpt-5.6-sol"))
        XCTAssertEqual(pricing.resolve(model: "grok-build-0.1")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "grok-4.3")?.inputPerMillion, 1.25)
    }

    /// Claude Fable 5 (carried over from the old manifest tests): priced at 2x standard Claude 4.8
    /// Opus, with thinking/effort slug variants resolving to the same rates.
    func testClaudeFable5PricingAndAliases() throws {
        let pricing = Self.pricing
        let fable = try XCTUnwrap(pricing.resolve(model: "claude-fable-5-thinking"))
        XCTAssertEqual(pricing.resolve(model: "claude-fable-5-thinking-xhigh"), fable)
        XCTAssertEqual(fable.inputPerMillion, 10.0)
        XCTAssertEqual(fable.outputPerMillion, 50.0)

        let opus48 = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-8"))
        XCTAssertEqual(fable.inputPerMillion, opus48.inputPerMillion * 2)
        XCTAssertEqual(fable.outputPerMillion, opus48.outputPerMillion * 2)
    }

    /// Claude Sonnet 5: same API pool rates as Claude 4.6 Sonnet; thinking/effort slugs resolve to
    /// one canonical entry.
    func testClaudeSonnet5PricingAndAliases() throws {
        let pricing = Self.pricing
        let sonnet5 = try XCTUnwrap(pricing.resolve(model: "claude-sonnet-5-thinking-high"))
        XCTAssertEqual(sonnet5.inputPerMillion, 3.0)
        XCTAssertEqual(sonnet5.outputPerMillion, 15.0)
        XCTAssertEqual(sonnet5.cacheWritePerMillion, 3.75)
        XCTAssertEqual(sonnet5.cacheReadPerMillion, 0.3)

        let sonnet46 = try XCTUnwrap(pricing.resolve(model: "claude-4.6-sonnet"))
        XCTAssertEqual(sonnet5.inputPerMillion, sonnet46.inputPerMillion)
        XCTAssertEqual(sonnet5.outputPerMillion, sonnet46.outputPerMillion)
    }

    /// Claude Opus 5: standard Opus-tier rates from the supplement (no public catalog lists it yet),
    /// with the `[1m]`, thinking/effort, and fast slug variants resolving to the right entry.
    func testClaudeOpus5PricingAndAliases() throws {
        let pricing = Self.pricing
        let opus5 = try XCTUnwrap(pricing.resolve(model: "claude-opus-5"))
        XCTAssertEqual(opus5.inputPerMillion, 5.0)
        XCTAssertEqual(opus5.cacheWritePerMillion, 6.25)
        XCTAssertEqual(opus5.cacheReadPerMillion, 0.5)
        XCTAssertEqual(opus5.outputPerMillion, 25.0)
        XCTAssertEqual(pricing.resolve(model: "claude-opus-5[1m]"), opus5)
        XCTAssertEqual(pricing.resolve(model: "claude-opus-5-thinking-xhigh"), opus5)

        let opus5Fast = try XCTUnwrap(pricing.resolve(model: "claude-opus-5-thinking-high-fast"))
        XCTAssertEqual(opus5Fast.inputPerMillion, opus5.inputPerMillion * 2)
        XCTAssertEqual(opus5Fast.outputPerMillion, opus5.outputPerMillion * 2)

        let opus48 = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-8"))
        XCTAssertEqual(opus5.inputPerMillion, opus48.inputPerMillion)
        XCTAssertEqual(opus5.outputPerMillion, opus48.outputPerMillion)
        XCTAssertEqual(opus5.fastMultiplier, opus48.fastMultiplier)
    }

    /// Claude logs signal fast mode with a `speed` field while the model stays `claude-opus-5`, so
    /// the base entry itself must carry the 2x multiplier — the `-fast` slug is never involved.
    func testClaudeOpus5FastModeBillsAtTwiceBaseRate() throws {
        let pricing = Self.pricing
        let opus5 = try XCTUnwrap(pricing.resolve(model: "claude-opus-5"))
        XCTAssertEqual(opus5.fastMultiplier, 2.0)

        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        var fastTokens = tokens
        fastTokens.isFast = true
        XCTAssertEqual(opus5.costDollars(for: fastTokens), opus5.costDollars(for: tokens) * 2, accuracy: 0.000_001)
    }

    /// Kimi K3: Cursor's published rates. Cursor lists no separate cache-write fee, so cache writes
    /// bill at the input rate, and the effort suffixes Cursor's CSV uses fold into the one entry.
    func testKimiK3PricingAndAliases() throws {
        let pricing = Self.pricing
        let k3 = try XCTUnwrap(pricing.resolve(model: "kimi-k3"))
        XCTAssertEqual(k3.inputPerMillion, 3.0)
        XCTAssertEqual(k3.cacheWritePerMillion, 3.0)
        XCTAssertEqual(k3.cacheReadPerMillion, 0.3)
        XCTAssertEqual(k3.outputPerMillion, 15.0)
        XCTAssertEqual(pricing.resolve(model: "kimi-k3-max"), k3)
        XCTAssertEqual(pricing.resolve(model: "kimi-k3-high"), k3)
        XCTAssertEqual(pricing.resolve(model: "kimi-k3-code"), k3)
        // K3 must not collapse into the cheaper K2.7 entry.
        XCTAssertNotEqual(pricing.resolve(model: "kimi-k2.7-code"), k3)
    }

    /// Cursor's CSV still carries a bare, unversioned `composer` slug from before the model was
    /// numbered. It maps to the current non-fast Composer so those rows price instead of tripping
    /// the unknown-model warning, and must not pick up the fast variant's higher rates.
    func testBareComposerSlugPricesAsCurrentComposer() throws {
        let pricing = Self.pricing
        let composer = try XCTUnwrap(pricing.resolve(model: "composer"))
        XCTAssertEqual(composer, pricing.resolve(model: "composer-2.5"))
        XCTAssertNotEqual(composer, pricing.resolve(model: "composer-2.5-fast"))
    }

    /// Cursor Router rows name the routed model in prose ("Opus 5 (Auto Balanced)") instead of a
    /// slug, so each label needs its own alias. The mode inside the parentheses is free-form: Cursor
    /// has shipped plain `(Auto)` and `(Auto Balanced)`, and the docs also name Cost and Intelligence.
    func testCursorRouterLabelsPriceAsTheRoutedModel() throws {
        let pricing = Self.pricing
        let expected: [String: String] = [
            "Opus 5 (Auto Balanced)": "claude-opus-5",
            "Claude Opus 5 (Auto)": "claude-opus-5",
            "Opus 4.8 (Auto)": "claude-opus-4-8",
            "Sonnet 5 (Auto Intelligence)": "claude-sonnet-5",
            "Fable 5 (Auto Balanced)": "claude-fable-5",
            "Haiku 4.5 (Auto Cost)": "claude-haiku-4-5",
            "Composer 2.5 (Auto)": "composer-2.5",
            "Composer 2.5 Fast (Auto)": "composer-2.5-fast",
            "Composer 2 (Auto Balanced)": "composer-2",
            "Grok 4.6 (Auto Intelligence)": "grok-4.6",
            "Cursor Grok 4.6 Fast (Auto)": "grok-4.6-fast",
            "Grok 4.5 (Auto Intelligence)": "grok-4.5",
            "Cursor Grok 4.5 Fast (Auto)": "grok-4.5-fast",
            "GPT-5.5 (Auto)": "gpt-5.5",
            "GPT-5.6 Sol (Auto Cost)": "gpt-5.6-sol",
            "GPT-5.6 Luna (Auto)": "gpt-5.6-luna",
            "Gemini 3.1 Pro (Auto Balanced)": "gemini-3.1-pro-preview",
            "Gemini 3.6 Flash (Auto)": "gemini-3.6-flash",
            "Gemini 3.7 Flash (Auto Balanced)": "gemini-3.7-flash",
            "GLM 5.2 (Auto)": "glm-5.2",
            "Kimi K3 (Auto Intelligence)": "kimi-k3"
        ]
        for (label, canonical) in expected {
            XCTAssertEqual(
                pricing.supplement.canonicalName(for: label), canonical,
                "router label '\(label)' should canonicalize to \(canonical)"
            )
            XCTAssertEqual(
                pricing.resolve(model: label), pricing.resolve(model: canonical),
                "router label '\(label)' should price exactly like \(canonical)"
            )
        }
        // A directly picked model keeps its own slug: the router alias must not swallow plain names.
        XCTAssertNil(pricing.supplement.canonicalName(for: "Opus 5"))
    }

    func testGPT56PricingAndAliases() throws {
        let pricing = Self.pricing
        let sol = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-sol-ultra"))
        XCTAssertEqual(sol.inputPerMillion, 5.0)
        XCTAssertEqual(sol.cacheWritePerMillion, 6.25)
        XCTAssertEqual(sol.cacheReadPerMillion, 0.5)
        XCTAssertEqual(sol.outputPerMillion, 30.0)
        let solFast = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-sol-ultra-fast"))
        XCTAssertEqual(solFast.inputPerMillion, 10.0)
        XCTAssertEqual(solFast.cacheWritePerMillion, 12.5)
        XCTAssertEqual(solFast.cacheReadPerMillion, 1.0)
        XCTAssertEqual(solFast.outputPerMillion, 60.0)

        let terra = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-terra-high"))
        XCTAssertEqual(terra.inputPerMillion, 2.0)
        XCTAssertEqual(terra.cacheWritePerMillion, 2.5)
        XCTAssertEqual(terra.cacheReadPerMillion, 0.2)
        XCTAssertEqual(terra.outputPerMillion, 12.0)
        let terraFast = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-terra-high-fast"))
        XCTAssertEqual(terraFast.inputPerMillion, 4.0)
        XCTAssertEqual(terraFast.cacheWritePerMillion, 5.0)
        XCTAssertEqual(terraFast.cacheReadPerMillion, 0.4)
        XCTAssertEqual(terraFast.outputPerMillion, 24.0)

        let luna = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-luna"))
        XCTAssertEqual(luna.inputPerMillion, 0.2)
        XCTAssertEqual(luna.cacheWritePerMillion, 0.25)
        XCTAssertEqual(luna.cacheReadPerMillion, 0.02)
        XCTAssertEqual(luna.outputPerMillion, 1.2)
        let lunaFast = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-luna-fast"))
        XCTAssertEqual(lunaFast.inputPerMillion, 0.4)
        XCTAssertEqual(lunaFast.cacheWritePerMillion, 0.5)
        XCTAssertEqual(lunaFast.cacheReadPerMillion, 0.04)
        XCTAssertEqual(lunaFast.outputPerMillion, 2.4)
    }

    /// Opus 4.7/4.8 fast modes: Cursor's published rates (supplement overrides) win over the
    /// stale models.dev entries. Per Cursor, 4.8 fast is 3x cheaper per token than 4.7 fast.
    func testOpusFastModeSupplementOverrides() throws {
        let pricing = Self.pricing
        let opus47Fast = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-7-thinking-high-fast"))
        XCTAssertEqual(opus47Fast.inputPerMillion, 30)
        XCTAssertEqual(opus47Fast.cacheWritePerMillion, 37.5)
        XCTAssertEqual(opus47Fast.cacheReadPerMillion, 3)
        XCTAssertEqual(opus47Fast.outputPerMillion, 150)

        let opus48Fast = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-8-thinking-high-fast"))
        XCTAssertEqual(opus48Fast.inputPerMillion, opus47Fast.inputPerMillion / 3)
        XCTAssertEqual(opus48Fast.outputPerMillion, opus47Fast.outputPerMillion / 3)
    }

    /// GLM 5.2: the high/max effort slugs resolve to the shared entry (LiteLLM's Cloudflare listing);
    /// no separate cache-write price, so cache writes bill at the input rate. Slugs outside the
    /// high/max allowlist stay unpriced.
    func testGLM52PricingAndAliases() throws {
        let pricing = Self.pricing
        let glm = try XCTUnwrap(pricing.resolve(model: "glm-5.2-max"))
        XCTAssertEqual(glm.inputPerMillion, 1.4)
        XCTAssertEqual(glm.cacheWritePerMillion, 1.4)
        XCTAssertEqual(glm.cacheReadPerMillion, 0.26)
        XCTAssertEqual(glm.outputPerMillion, 4.4)

        let outputOnly = TokenBreakdown(output: 1_000_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "glm-5.2-high", tokens: outputOnly)!, 4.4, accuracy: 1e-9)
        XCTAssertNil(pricing.estimatedCostDollars(model: "glm-5.2-bogus", tokens: outputOnly))
    }

    /// Grok CLI model ids route through the alias rules to their catalog entries.
    func testGrokCLIModelAliases() {
        let pricing = Self.pricing
        XCTAssertEqual(pricing.resolve(model: "grok-build")?.inputPerMillion, 1)
        // grok-proxy is the recent Grok Build CLI log slug for the same model.
        XCTAssertEqual(pricing.resolve(model: "grok-proxy"), pricing.resolve(model: "grok-build-0.1"))
        XCTAssertEqual(pricing.resolve(model: "grok-composer-2.5-fast")?.inputPerMillion, 3)
    }

    /// Grok 4.5 (Cursor + SpaceXAI first-party): standard and fast rates from Cursor docs, with
    /// effort slugs collapsing to the same entries.
    func testGrok45PricingAndAliases() throws {
        let pricing = Self.pricing
        let standard = try XCTUnwrap(pricing.resolve(model: "grok-4.5-high"))
        XCTAssertEqual(standard.inputPerMillion, 2.0)
        XCTAssertEqual(standard.cacheWritePerMillion, 2.0)
        XCTAssertEqual(standard.cacheReadPerMillion, 0.5)
        XCTAssertEqual(standard.outputPerMillion, 6.0)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5"), standard)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-build"), standard)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-low"), standard)

        let fast = try XCTUnwrap(pricing.resolve(model: "grok-4.5-fast"))
        XCTAssertEqual(fast.inputPerMillion, 4.0)
        XCTAssertEqual(fast.cacheWritePerMillion, 4.0)
        XCTAssertEqual(fast.cacheReadPerMillion, 1.0)
        XCTAssertEqual(fast.outputPerMillion, 12.0)
        // Cursor CSV uses fast-before-effort (`grok-4.5-fast-high`); also accept effort-before-fast.
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-fast-high"), fast)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-fast-medium"), fast)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-fast-xhigh"), fast)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-xhigh"), standard)
        XCTAssertEqual(pricing.resolve(model: "grok-4-5-xhigh"), standard)
        XCTAssertEqual(pricing.resolve(model: "grok-4-5-xhigh-fast"), fast)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-medium-fast"), fast)
        // Cursor usage export sometimes prefixes first-party Grok with `cursor-`.
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.5-high-fast"), fast)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.5-fast-high"), fast)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.5-high"), standard)
    }

    /// Grok 4.6 (Cursor + SpaceXAI first-party): same published table rates as Grok 4.5, with
    /// effort slugs and the `cursor-` CSV prefix collapsing to the same entries.
    func testGrok46PricingAndAliases() throws {
        let pricing = Self.pricing
        let standard = try XCTUnwrap(pricing.resolve(model: "grok-4.6-high"))
        XCTAssertEqual(standard.inputPerMillion, 2.0)
        XCTAssertEqual(standard.cacheWritePerMillion, 2.0)
        XCTAssertEqual(standard.cacheReadPerMillion, 0.5)
        XCTAssertEqual(standard.outputPerMillion, 6.0)
        XCTAssertEqual(pricing.resolve(model: "grok-4.6"), standard)
        XCTAssertEqual(pricing.resolve(model: "grok-4.6-build"), standard)
        XCTAssertEqual(pricing.resolve(model: "grok-4.6-low"), standard)

        let fast = try XCTUnwrap(pricing.resolve(model: "grok-4.6-fast"))
        XCTAssertEqual(fast.inputPerMillion, 4.0)
        XCTAssertEqual(fast.cacheWritePerMillion, 4.0)
        XCTAssertEqual(fast.cacheReadPerMillion, 1.0)
        XCTAssertEqual(fast.outputPerMillion, 12.0)
        XCTAssertEqual(pricing.resolve(model: "grok-4.6-fast-high"), fast)
        XCTAssertEqual(pricing.resolve(model: "grok-4.6-high-fast"), fast)
        XCTAssertEqual(pricing.resolve(model: "grok-4.6-xhigh"), standard)
        XCTAssertEqual(pricing.resolve(model: "grok-4-6-xhigh"), standard)
        XCTAssertEqual(pricing.resolve(model: "grok-4-6-xhigh-fast"), fast)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.6-high-fast"), fast)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.6-fast-high"), fast)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.6-high"), standard)
        XCTAssertEqual(pricing.supplement.canonicalName(for: "cursor-grok-4.6-high"), "grok-4.6")
        XCTAssertEqual(pricing.supplement.canonicalName(for: "cursor-grok-4.6-high-fast"), "grok-4.6-fast")
    }

    /// Kimi K2.7 Code: Cursor's published rates override messy public-catalog entries.
    func testKimiK27CodePricingAndAliases() throws {
        let pricing = Self.pricing
        let kimi = try XCTUnwrap(pricing.resolve(model: "kimi-k2.7-code"))
        XCTAssertEqual(kimi.inputPerMillion, 0.95)
        XCTAssertEqual(kimi.cacheWritePerMillion, 0.95)
        XCTAssertEqual(kimi.cacheReadPerMillion, 0.19)
        XCTAssertEqual(kimi.outputPerMillion, 4.0)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2.7"), kimi)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2p7"), kimi)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2p7-code"), kimi)
    }

    func testCostSumsAllBucketsAndUnpricedIsNil() throws {
        let pricing = Self.pricing
        let entry = try XCTUnwrap(pricing.resolve(model: "composer-1"))
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        let expected = entry.inputPerMillion + entry.cacheWritePerMillion + entry.cacheReadPerMillion + entry.outputPerMillion
        XCTAssertEqual(pricing.estimatedCostDollars(model: "composer-1", tokens: tokens)!, expected, accuracy: 1e-9)
        XCTAssertNil(pricing.estimatedCostDollars(model: "nope", tokens: tokens))
    }
}

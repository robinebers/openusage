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
        let expectedInputRates: [(String, Double)] = [
            ("auto", 1.25), ("claude-4.5-sonnet-thinking", 3),
            ("claude-4.6-opus-max-thinking", 5), ("claude-4.6-opus-max-thinking-fast", 30),
            ("gpt-5.5-xhigh-fast", 12.5),
            ("gpt-5.6-sol-ultra", 5), ("gpt-5.6-sol-ultra-fast", 10),
            ("gpt-5.6-terra-high", 2), ("gpt-5.6-terra-high-fast", 4),
            ("gpt-5.6-luna", 0.2), ("gpt-5.6-luna-fast", 0.4),
            ("gemini-3.6-flash-high", 1.5), ("gemini-3.7-flash-high", 0.75),
            ("grok-4-20-thinking", 2), ("grok-4.5", 2),
            ("grok-4.5-fast-high", 4), ("grok-4.5-high-fast", 4),
            ("cursor-grok-4.5-high-fast", 4), ("cursor-grok-4.6-high", 2),
            ("cursor-grok-4.6-high-fast", 4), ("grok-4-6-xhigh", 2),
            ("grok-4-6-xhigh-fast", 4), ("kimi-k2p5", 0.6),
            ("kimi-k2.7-code", 0.95), ("kimi-k2p7", 0.95), ("kimi-k3-max", 3),
            ("claude-4.7-opus-high-thinking", 5), ("claude-4.7-opus-max-thinking-fast", 30),
            ("glm-5.2-max", 1.4), ("glm-5.3-max", 1.4),
            ("claude-fable-5-1-thinking-high", 10),
            ("grok-bot-default", 2), ("grok-bot-automation", 2), ("grok-bot-cua", 2)
        ]
        for (model, expected) in expectedInputRates {
            XCTAssertEqual(pricing.resolve(model: model)?.inputPerMillion, expected, model)
        }
        XCTAssertEqual(pricing.resolve(model: "gemini-3.7-flash-high")?.outputPerMillion, 3.75)
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

    func testAntigravityGeminiModelVariantsReuseExistingCatalogRates() {
        let pricing = Self.pricing
        let expected: [String: String] = [
            "gemini-2.5-flash-none": "gemini-2.5-flash",
            "gemini-3-flash-a": "gemini-3-flash-preview",
            "gemini-3-flash-b-high": "gemini-3-flash-preview",
            "gemini-3-flash-none-preview": "gemini-3-flash-preview",
            "gemini-3.5-flash-high-preview": "gemini-3.5-flash",
            "gemini-3.6-flash-none": "gemini-3.6-flash",
            "gemini-3.7-flash-xhigh-preview": "gemini-3.7-flash",
            "gemini-3-pro-low": "gemini-3-pro-preview",
            "gemini-3-pro-high-preview": "gemini-3-pro-preview",
            "gemini-3.1-pro-none-preview": "gemini-3.1-pro-preview"
        ]

        for (variant, canonical) in expected {
            XCTAssertEqual(pricing.supplement.canonicalName(for: variant), canonical, "wrong alias for '\(variant)'")
            XCTAssertEqual(pricing.resolve(model: variant), pricing.resolve(model: canonical), "wrong rates for '\(variant)'")
        }
        XCTAssertNil(pricing.supplement.canonicalName(for: "gemini-3-pro"))
    }

    /// Claude Fable 5.1: same $10/$50 input/output as Fable 5, but cache reads are $0.25/M
    /// (0.025x). Cursor CSV slugs (`claude-fable-5-1-thinking-*`) and the Anthropic API id
    /// (`claude-fable-5-1`) must not collapse into the Fable 5 catalog entry.
    func testClaudeFable51PricingAndAliases() throws {
        let pricing = Self.pricing
        let fable51 = try XCTUnwrap(pricing.resolve(model: "claude-fable-5-1-thinking-high"))
        XCTAssertEqual(fable51.inputPerMillion, 10.0)
        XCTAssertEqual(fable51.cacheWritePerMillion, 12.5)
        XCTAssertEqual(fable51.cacheReadPerMillion, 0.25)
        XCTAssertEqual(fable51.outputPerMillion, 50.0)

        for model in [
            "claude-fable-5-1", "claude-fable-5.1", "claude-fable-5-1-thinking",
            "claude-fable-5-1-thinking-low", "claude-fable-5-1-thinking-medium",
            "claude-fable-5.1-thinking-xhigh", "claude-fable-5-1[1m]"
        ] {
            XCTAssertEqual(pricing.supplement.canonicalName(for: model), "claude-fable-5.1", model)
            XCTAssertEqual(pricing.resolve(model: model), fable51, model)
        }

        let fable5 = try XCTUnwrap(pricing.resolve(model: "claude-fable-5"))
        XCTAssertEqual(fable5.inputPerMillion, fable51.inputPerMillion)
        XCTAssertEqual(fable5.outputPerMillion, fable51.outputPerMillion)
        XCTAssertNotEqual(fable5.cacheReadPerMillion, fable51.cacheReadPerMillion)
        XCTAssertEqual(pricing.supplement.canonicalName(for: "claude-fable-5-thinking-high"), "claude-fable-5")
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
            "Fable 5.1 (Auto Balanced)": "claude-fable-5.1",
            "Claude Fable 5.1 (Auto)": "claude-fable-5.1",
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
            "GLM 5.3 (Auto Intelligence)": "glm-5.3",
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
        let expectedRates: [(String, [Double])] = [
            ("gpt-5.6-sol-ultra", [5, 6.25, 0.5, 30]),
            ("gpt-5.6-sol-ultra-fast", [10, 12.5, 1, 60]),
            ("gpt-5.6-terra-high", [2, 2.5, 0.2, 12]),
            ("gpt-5.6-terra-high-fast", [4, 5, 0.4, 24]),
            ("gpt-5.6-luna", [0.2, 0.25, 0.02, 1.2]),
            ("gpt-5.6-luna-fast", [0.4, 0.5, 0.04, 2.4])
        ]
        for (model, expected) in expectedRates {
            let actual = try XCTUnwrap(pricing.resolve(model: model))
            XCTAssertEqual(
                [actual.inputPerMillion, actual.cacheWritePerMillion, actual.cacheReadPerMillion, actual.outputPerMillion],
                expected,
                model
            )
        }
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

    /// GLM 5.3 has its own identity and Z.ai's published rates; its three supported effort levels
    /// and provider-prefixed API identifiers all resolve to that same distinct model.
    func testGLM53PricingAndAliases() throws {
        let pricing = Self.pricing
        let glm = try XCTUnwrap(pricing.resolve(model: "glm-5.3"))
        XCTAssertEqual(glm.inputPerMillion, 1.4)
        XCTAssertEqual(glm.cacheWritePerMillion, 1.4)
        XCTAssertEqual(glm.cacheReadPerMillion, 0.26)
        XCTAssertEqual(glm.outputPerMillion, 4.4)

        for model in [
            "glm-5.3-low", "glm-5.3-high", "glm-5.3-max",
            "z-ai/glm-5.3", "zai/glm-5.3-max", "ZHIPU/GLM-5.3"
        ] {
            XCTAssertEqual(pricing.supplement.canonicalName(for: model), "glm-5.3", model)
            XCTAssertEqual(pricing.resolve(model: model), glm, model)
        }

        let outputOnly = TokenBreakdown(output: 1_000_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "glm-5.3-low", tokens: outputOnly)!, 4.4, accuracy: 1e-9)
        XCTAssertNil(pricing.estimatedCostDollars(model: "glm-5.3-medium", tokens: outputOnly))
    }

    /// Grok CLI model ids route through the alias rules to their catalog entries.
    func testGrokCLIModelAliases() {
        let pricing = Self.pricing
        XCTAssertEqual(pricing.resolve(model: "grok-build")?.inputPerMillion, 1)
        // grok-proxy is the recent Grok Build CLI log slug for the same model.
        XCTAssertEqual(pricing.resolve(model: "grok-proxy"), pricing.resolve(model: "grok-build-0.1"))
        XCTAssertEqual(pricing.resolve(model: "grok-composer-2.5-fast")?.inputPerMillion, 3)
    }

    /// Both first-party Grok versions share rates and accept effort, separator, and Cursor-prefix variants.
    func testGrokPricingAndAliases() throws {
        let pricing = Self.pricing
        for version in ["4.5", "4.6"] {
            let dashedVersion = version.replacingOccurrences(of: ".", with: "-")
            let standard = try XCTUnwrap(pricing.resolve(model: "grok-\(version)-high"))
            let fast = try XCTUnwrap(pricing.resolve(model: "grok-\(version)-fast"))
            XCTAssertEqual(
                [standard.inputPerMillion, standard.cacheWritePerMillion, standard.cacheReadPerMillion, standard.outputPerMillion],
                [2, 2, 0.5, 6],
                version
            )
            XCTAssertEqual(
                [fast.inputPerMillion, fast.cacheWritePerMillion, fast.cacheReadPerMillion, fast.outputPerMillion],
                [4, 4, 1, 12],
                version
            )

            for alias in [
                "grok-\(version)", "grok-\(version)-build", "grok-\(version)-low",
                "grok-\(version)-xhigh", "grok-\(dashedVersion)-xhigh", "cursor-grok-\(version)-high"
            ] {
                XCTAssertEqual(pricing.resolve(model: alias), standard, alias)
            }
            for alias in [
                "grok-\(version)-fast-high", "grok-\(version)-fast-medium", "grok-\(version)-fast-xhigh",
                "grok-\(version)-high-fast", "grok-\(version)-medium-fast", "grok-\(dashedVersion)-xhigh-fast",
                "cursor-grok-\(version)-high-fast", "cursor-grok-\(version)-fast-high"
            ] {
                XCTAssertEqual(pricing.resolve(model: alias), fast, alias)
            }
            XCTAssertEqual(pricing.supplement.canonicalName(for: "cursor-grok-\(version)-high"), "grok-\(version)")
            XCTAssertEqual(pricing.supplement.canonicalName(for: "cursor-grok-\(version)-high-fast"), "grok-\(version)-fast")
        }

        let grok46 = try XCTUnwrap(pricing.resolve(model: "grok-4.6"))
        for bot in ["grok-bot-automation", "grok-bot-cua", "grok-bot-default"] {
            XCTAssertEqual(pricing.supplement.canonicalName(for: bot), "grok-4.6", bot)
            XCTAssertEqual(pricing.resolve(model: bot), grok46, bot)
        }
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
}

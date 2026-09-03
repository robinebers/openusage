import Foundation

/// Codex-specific request pricing shared by native rollout logs and supplementary agents. The public
/// pricing catalogs provide base model rates, but Codex also has provider-specific long-context,
/// prompt-cache, and priority-tier rules that must be applied consistently regardless of which local
/// tool produced the request.
enum CodexUsagePricing {
    /// Everything Codex pricing derives from the model slug alone, resolved once so a scanner pricing
    /// thousands of requests does not re-walk the supplement's alias rules per row.
    struct Prepared: Sendable {
        /// Base rates with Codex's long-context, cache, and priority adjustments already applied.
        var rates: ModelRates
        var fastTier: Bool
    }

    /// The catalog lookup Codex layers its rules on. `rates` is nil when the model cannot be priced;
    /// the other fields stay meaningful so callers can still apply their own fallback-model handling.
    struct RateResolution {
        var rates: ModelRates?
        /// The unscaled base model whose name selects Codex's long-context and priority rules.
        var rateModel: String
        var isFastAlias: Bool
        /// The unscaled base entry existed, so the Codex multiplier can be applied to it exactly once.
        var hasBaseRates: Bool
    }

    /// Codex speed is a provider tier, not Cursor's `-fast` price variant. Resolve a fast alias through
    /// its unscaled base rates so the Codex multiplier applies once; if a fast-only model has no base
    /// entry, its already-scaled rate is retained and no second multiplier is applied.
    static func resolveRates(pricing: ModelPricing, model: String) -> RateResolution {
        let canonicalModel = pricing.supplement.canonicalName(for: model) ?? model
        let isFastAlias = canonicalModel.hasSuffix("-fast")
        let rateModel = isFastAlias ? String(canonicalModel.dropLast("-fast".count)) : canonicalModel
        let baseRates = pricing.resolve(model: rateModel)
        return RateResolution(
            rates: baseRates ?? pricing.resolve(model: model),
            rateModel: rateModel,
            isFastAlias: isFastAlias,
            hasBaseRates: baseRates != nil
        )
    }

    /// Resolves the model once. Callers pricing many requests should hold the result and reuse it
    /// rather than calling `estimatedCost` per request.
    static func prepare(pricing: ModelPricing, model: String) -> Prepared? {
        let resolution = resolveRates(pricing: pricing, model: model)
        guard let rates = resolution.rates else { return nil }
        return Prepared(
            rates: adjusted(rates, model: resolution.rateModel),
            fastTier: resolution.isFastAlias && resolution.hasBaseRates
        )
    }

    /// Prices an already normalized request. Unlike native Codex rollout events, `tokens.input` here
    /// is non-cached input; cache reads/writes are disjoint buckets in `TokenBreakdown`.
    static func estimatedCost(pricing: ModelPricing, model: String, tokens: TokenBreakdown) -> Double? {
        guard let prepared = prepare(pricing: pricing, model: model) else { return nil }
        return cost(prepared: prepared, tokens: tokens)
    }

    static func cost(prepared: Prepared, tokens: TokenBreakdown) -> Double {
        var pricedTokens = tokens
        pricedTokens.isFast = prepared.fastTier
        return prepared.rates.costDollars(for: pricedTokens)
    }

    /// Lower-level entry point for the native scanner, which resolves its own rates so it can swap in
    /// the user's selected fallback model and carry the per-event priority flag.
    static func cost(rates: ModelRates, tokens: TokenBreakdown, model: String, fastTier: Bool) -> Double {
        cost(prepared: Prepared(rates: adjusted(rates, model: model), fastTier: fastTier), tokens: tokens)
    }

    /// Applies every model-derived Codex adjustment in one pass so the slug is normalized once.
    private static func adjusted(_ rates: ModelRates, model: String) -> ModelRates {
        let base = datedBaseModel(model)
        var effective = rates
        if let longContext = longContextRates(base: base) {
            effective.inputAbove200kPerMillion = longContext.input
            effective.outputAbove200kPerMillion = longContext.output
            effective.cacheReadAbove200kPerMillion = longContext.cacheRead
            effective.longContextThresholdTokens = 272_000
        }
        // Either the model publishes no cache discount at all, or the catalog gave no explicit
        // cache-read rate. Both mean cached input is estimated at the full input rate.
        if hasNoCacheDiscount(base: base) || !rates.cacheReadIsExplicit {
            effective.cacheReadPerMillion = effective.inputPerMillion
            effective.cacheReadAbove200kPerMillion = effective.inputAbove200kPerMillion
        }
        effective.fastMultiplier = priorityMultiplier(base: base, rates: rates)
        return effective
    }

    static func priorityMultiplier(for model: String, rates: ModelRates) -> Double {
        priorityMultiplier(base: datedBaseModel(model), rates: rates)
    }

    private static func priorityMultiplier(base: String, rates: ModelRates) -> Double {
        switch base {
        case "gpt-5.5", "gpt-5.5-pro": return 2.5
        case "gpt-5.4", "gpt-5.4-pro",
             "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna": return 2
        default: return rates.fastMultiplier == 1 ? 2 : rates.fastMultiplier
        }
    }

    private static func hasNoCacheDiscount(base: String) -> Bool {
        switch base {
        case "gpt-5.4-pro", "gpt-5.5-pro": return true
        default: return false
        }
    }

    private static func longContextRates(base: String) -> (input: Double, output: Double, cacheRead: Double)? {
        switch base {
        case "gpt-5.4": return (5, 22.5, 0.5)
        case "gpt-5.4-pro": return (60, 270, 60)
        case "gpt-5.5": return (10, 45, 1)
        case "gpt-5.5-pro": return (60, 270, 60)
        case "gpt-5.6-sol": return (10, 45, 1)
        case "gpt-5.6-terra": return (4, 18, 0.4)
        case "gpt-5.6-luna": return (0.4, 1.8, 0.04)
        default: return nil
        }
    }

    /// Strips a trailing `-YYYY-MM-DD` or `-YYYYMMDD` snapshot suffix. Runs for every priced request,
    /// so it inspects characters directly instead of compiling a regex per call.
    static func datedBaseModel(_ model: String) -> String {
        // "-YYYY-MM-DD" then "-YYYYMMDD"; "d" marks a digit, "-" a literal dash.
        for pattern in ["-dddd-dd-dd", "-dddddddd"] where model.count > pattern.count {
            let suffix = model.suffix(pattern.count)
            let matches = zip(suffix, pattern).allSatisfy { character, token in
                token == "d" ? character.isNumber : character == token
            }
            if matches { return String(model.dropLast(pattern.count)) }
        }
        return model
    }
}

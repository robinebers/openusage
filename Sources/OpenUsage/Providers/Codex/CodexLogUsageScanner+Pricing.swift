import Foundation

/// Event pricing stays separate from parsing: changing a preference reuses cached token events.
/// Known rates always win; only unresolved, named events can use an explicitly selected reference.
/// Unpriced usage remains excluded and warned about when no usable reference is selected.
extension CodexLogUsageScanner {
    // MARK: - Aggregation

    private struct EventKey: Hashable {
        var timestamp: Date
        var model: String
        var pricingModel: String?
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
    }

    static func aggregate(
        events: [Event], since: Date, pricing: ModelPricing, fallbackModel: String? = nil
    ) -> LogUsageScan {
        let fallbackRates = fallbackModel.flatMap { pricing.fallbackRates(model: $0, providerID: "codex") }
        if fallbackModel != nil && fallbackRates == nil {
            AppLog.warn(LogTag.plugin("codex"), "Selected fallback pricing is unavailable; unpriced usage remains excluded.")
        }
        var seen: Set<EventKey> = []
        var accumulator = DailyUsageAccumulator()

        for event in events where event.timestamp >= since {
            let key = EventKey(
                timestamp: event.timestamp, model: event.model, pricingModel: event.pricingModel, input: event.input,
                cached: event.cached, output: event.output, reasoning: event.reasoning, total: event.total
            )
            guard seen.insert(key).inserted else { continue }

            let day = DailyUsageAccumulator.dayKey(from: event.timestamp)
            // One trimmed slug for pricing, the unknown-model warning, and the breakdown key alike —
            // diverging spellings would let the warning triangle and the hover panel disagree.
            let trimmedModel = event.model.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            guard let model = trimmedModel else {
                continue
            }
            let pricingModel = event.pricingModel ?? model
            let canonicalModel = pricing.supplement.canonicalName(for: pricingModel) ?? pricingModel
            let isFastAlias = canonicalModel.hasSuffix("-fast")
            var rateModel = isFastAlias ? String(canonicalModel.dropLast("-fast".count)) : canonicalModel

            // Codex speed is a provider tier, not Cursor's `-fast` price variant. Resolve a fast
            // alias through its unscaled base rates, then apply the Codex multiplier exactly once.
            // If a third-party fast-only model has no base entry, retain its already-scaled rate
            // and do not apply a second speed multiplier.
            let baseRates = pricing.resolve(model: rateModel)
            var resolvedRates = baseRates ?? pricing.resolve(model: pricingModel)
            var appliesCodexFastTier = isFastAlias ? baseRates != nil : event.isFast
            var usedFallback: String?
            // A reference can estimate the cost without making the model's own price known.
            // Keep the existing warning independently of whether an estimate can be included.
            if resolvedRates == nil, event.total > 0 {
                accumulator.addUnknownModel(day: day, model: model)
            }
            if resolvedRates == nil, let fallbackModel, let fallbackRates {
                resolvedRates = fallbackRates
                rateModel = fallbackModel
                appliesCodexFastTier = isFastAlias || event.isFast
                usedFallback = fallbackModel
            }
            guard let rates = resolvedRates else { continue }
            let eventCost = cost(
                rates: rates,
                event: event,
                model: rateModel,
                fastTier: appliesCodexFastTier,
                fastMultiplier: codexPriorityMultiplier(for: rateModel, rates: rates)
            )
            accumulator.add(
                day: day, tokens: event.total, cost: eventCost, model: model,
                fallbackPricingModel: usedFallback
            )
        }

        return accumulator.build()
    }

    static func cost(
        rates: ModelRates,
        event: Event,
        model: String,
        fastTier: Bool,
        fastMultiplier: Double
    ) -> Double {
        var effectiveRates = rates
        if let longContext = codexLongContextRates(for: model) {
            effectiveRates.inputAbove200kPerMillion = longContext.input
            effectiveRates.outputAbove200kPerMillion = longContext.output
            effectiveRates.cacheReadAbove200kPerMillion = longContext.cacheRead
            effectiveRates.longContextThresholdTokens = 272_000
        }
        if codexModelHasNoCacheDiscount(model) {
            effectiveRates.cacheReadPerMillion = effectiveRates.inputPerMillion
            effectiveRates.cacheReadAbove200kPerMillion = effectiveRates.inputAbove200kPerMillion
        } else if !rates.cacheReadIsExplicit {
            effectiveRates.cacheReadPerMillion = effectiveRates.inputPerMillion
            effectiveRates.cacheReadAbove200kPerMillion = effectiveRates.inputAbove200kPerMillion
        }
        effectiveRates.fastMultiplier = fastMultiplier

        let nonCached = max(0, event.input - event.cached)
        return effectiveRates.costDollars(for: TokenBreakdown(
            input: nonCached,
            cacheRead: event.cached,
            output: event.output,
            isFast: fastTier
        ))
    }

    private static func codexPriorityMultiplier(for model: String, rates: ModelRates) -> Double {
        let base = datedBaseModel(model)
        switch base {
        case "gpt-5.5", "gpt-5.5-pro": return 2.5
        case "gpt-5.4", "gpt-5.4-pro",
             "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna": return 2
        default: return rates.fastMultiplier == 1 ? 2 : rates.fastMultiplier
        }
    }

    private static func codexModelHasNoCacheDiscount(_ model: String) -> Bool {
        switch datedBaseModel(model) {
        case "gpt-5.4-pro", "gpt-5.5-pro": return true
        default: return false
        }
    }

    private static func codexLongContextRates(for model: String) -> (input: Double, output: Double, cacheRead: Double)? {
        switch datedBaseModel(model) {
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

    private static func datedBaseModel(_ model: String) -> String {
        model
            .replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
}

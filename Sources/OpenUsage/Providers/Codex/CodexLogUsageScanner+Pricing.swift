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
            let resolution = CodexUsagePricing.resolveRates(pricing: pricing, model: pricingModel)
            var rateModel = resolution.rateModel
            var resolvedRates = resolution.rates
            var appliesCodexFastTier = resolution.isFastAlias ? resolution.hasBaseRates : event.isFast
            var usedFallback: String?
            // A reference can estimate the cost without making the model's own price known.
            // Keep the existing warning independently of whether an estimate can be included.
            if resolvedRates == nil, event.total > 0 {
                accumulator.addUnknownModel(day: day, model: model)
            }
            if resolvedRates == nil, let fallbackModel, let fallbackRates {
                resolvedRates = fallbackRates
                rateModel = fallbackModel
                appliesCodexFastTier = resolution.isFastAlias || event.isFast
                usedFallback = fallbackModel
            }
            guard let rates = resolvedRates else { continue }
            let eventCost = cost(rates: rates, event: event, model: rateModel, fastTier: appliesCodexFastTier)
            accumulator.add(
                day: day, tokens: event.total, cost: eventCost, model: model,
                fallbackPricingModel: usedFallback
            )
        }

        return accumulator.build()
    }

    /// Native rollout events count cached tokens inside `input`; the shared estimator takes disjoint
    /// buckets, so the cached portion is subtracted here rather than in `CodexUsagePricing`.
    static func cost(rates: ModelRates, event: Event, model: String, fastTier: Bool) -> Double {
        CodexUsagePricing.cost(
            rates: rates,
            tokens: TokenBreakdown(
                input: max(0, event.input - event.cached), cacheRead: event.cached, output: event.output
            ),
            model: model,
            fastTier: fastTier
        )
    }
}

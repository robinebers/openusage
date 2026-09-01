import Foundation
import os

/// An immutable pricing snapshot: the supplement plus the two public catalogs, with the resolution
/// order ported from ccusage. `ModelPricingStore` builds one; scanners and mappers use it
/// synchronously for a whole parse pass.
///
/// Resolution for a model name:
/// 1. Supplement alias rules rewrite the slug to a canonical key (raw name kept as fallback).
/// 2. Supplement pricing (exact) — Cursor-native models live here.
/// 3. LiteLLM exact.
/// 4. `-fast` suffix: price the base model and scale by its fast multiplier; if no multiplier or
///    exact fast entry exists, leave it unpriced instead of silently using standard-speed rates.
/// 5. LiteLLM fuzzy (boundary-aware substring matching, for non-fast slugs only).
/// 6. models.dev exact — id-level gap-filler only. models.dev aggregates resellers under near-
///    identical bare ids (`glm-5-2` vs `glm-5.2`) with diverging rates, so fuzzy matching against
///    it risks wrong dollars; unknown slug variants stay unpriced (and visibly flagged) instead.
final class ModelPricing: Sendable {
    let supplement: PricingSupplement
    /// LiteLLM `model_prices_and_context_window.json` (bundled snapshot merged with fetched data).
    let primary: PricingCatalog
    /// models.dev `api.json` — gap-filler for models LiteLLM misses (e.g. `grok-build-0.1`).
    let secondary: PricingCatalog

    /// Resolution walks every catalog entry on a fuzzy miss, so memoize per model name. Shared
    /// across threads; a pricing snapshot is immutable so entries never invalidate.
    private let memo = OSAllocatedUnfairLock<[String: ModelRates?]>(initialState: [:])

    init(supplement: PricingSupplement, primary: PricingCatalog, secondary: PricingCatalog) {
        self.supplement = supplement
        self.primary = primary
        self.secondary = secondary
    }

    static let empty = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(), secondary: PricingCatalog())

    /// Rates for `model`, or nil when no source can price it (caller shows the unknown-model
    /// warning and counts tokens at $0).
    func resolve(model: String) -> ModelRates? {
        if let cached = memo.withLock({ $0[model] }) {
            return cached
        }
        let resolved = resolveUncached(model: model)
        memo.withLock { $0[model] = resolved }
        return resolved
    }

    /// Dollar cost of `tokens` for `model`, or nil when the model can't be priced. Aggregated sources
    /// can disable long-context tiers when they do not preserve individual request boundaries.
    func estimatedCostDollars(
        model: String,
        tokens: TokenBreakdown,
        applyLongContextRates: Bool = true
    ) -> Double? {
        guard let rates = resolve(model: model) else { return nil }
        return rates.costDollars(for: tokens, applyLongContextRates: applyLongContextRates)
    }

    private func resolveUncached(model: String) -> ModelRates? {
        if let canonical = supplement.canonicalName(for: model), canonical != model {
            return lookup(canonical) ?? lookup(model)
        }
        return lookup(model)
    }

    /// The secondary catalog is consulted only after the whole primary lookup misses, like ccusage —
    /// models.dev aggregates resellers whose rates can differ, so LiteLLM wins whenever it knows the
    /// model at all, and models.dev answers exact ids only (see the fuzzy note on the type).
    private func lookup(_ name: String) -> ModelRates? {
        if let entry = supplement.pricing[name] { return entry }
        if let exact = primary.findExact(name) { return exact.rates }
        if let fast = fastVariant(name) { return fast }
        if name.hasSuffix("-fast") { return secondary.findExact(name)?.rates }
        if let fuzzy = primary.findFuzzy(name) { return fuzzy.rates }
        if let exact = secondary.findExact(name) { return exact.rates }
        return nil
    }

    /// Prices `<base>-fast` slugs from their base entry when a fast multiplier is known. Returns
    /// nil when the multiplier is unknown; the caller may still accept an exact fast entry from
    /// models.dev, but never fuzzy-matches the standard-speed base rate.
    private func fastVariant(_ name: String) -> ModelRates? {
        guard name.hasSuffix("-fast") else { return nil }
        let base = String(name.dropLast("-fast".count))
        guard !base.isEmpty else { return nil }
        guard let (key, rates) = baseEntry(base) else { return nil }
        let multiplier: Double
        if rates.fastMultiplier != 1 {
            multiplier = rates.fastMultiplier
        } else if let supplementMultiplier = supplement.fastMultiplier(for: key) ?? supplement.fastMultiplier(for: base) {
            multiplier = supplementMultiplier
        } else {
            return nil
        }
        return rates.scaled(by: multiplier)
    }

    private func baseEntry(_ base: String) -> (key: String, rates: ModelRates)? {
        if let entry = supplement.pricing[base] { return (base, entry) }
        return primary.findExact(base)
            ?? primary.findFuzzy(base)
            ?? secondary.findExact(base)
    }
}

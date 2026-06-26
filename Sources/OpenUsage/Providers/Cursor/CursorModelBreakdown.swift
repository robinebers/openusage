import Foundation

/// Groups Cursor's per-row CSV usage into a per-model leaderboard. A port of cursorcat's
/// `ModelBreakdownAggregator`, simplified to OpenUsage's single cost path: rows are priced with the
/// locally-imputed `imputedCostDollars` that `CursorUsageCSV` already computes (cursorcat's optional
/// server "actual cost" mode was dropped in the OpenUsage port), and one window covers exactly the rows
/// passed in (the CSV is already fetched for the spend-tile window), so there is no date filtering here.
enum CursorModelBreakdown {
    /// Models below this share of total spend collapse into one "Other" row (see `foldLowSpendTail`).
    static let tailThresholdFraction = 0.03
    /// The catch-all row's display name.
    static let otherRowName = "Other"

    private struct VariantAccumulator {
        let isUnpriced: Bool
        var totalCostDollars: Double = 0
    }

    private struct Accumulator {
        let displayName: String
        let isUnpriced: Bool
        var totalTokens: Int = 0
        var totalCostDollars: Double = 0
        /// Per-raw-model cost within this family, keyed by the CSV model string — drives the hover
        /// breakdown (e.g. `gpt-5.5` vs `gpt-5.5-fast`).
        var variants: [String: VariantAccumulator] = [:]
    }

    /// Aggregate parsed CSV rows into spend-sorted model entries.
    ///
    /// Rows are bucketed by model *family* (`CursorPricing.family`), so pricing variants of one model
    /// (e.g. `gpt-5.5` and `gpt-5.5-fast`) collapse into a single "GPT-5.5" row. An unknown/unpriced
    /// model has no family, so it keys by its raw id and is flagged `isUnpriced` (its cost is unknown,
    /// not zero). Dollars are summed per family as `Double`, then snapped to whole cents once (matching
    /// the day-tile rounding), so a busy family's total can't drift sub-cent across many rows. The
    /// result is sorted by spend descending, then tokens, then name — the leaderboard order.
    static func aggregate(rows: [CursorUsageCSVRow]) -> [ModelUsageEntry] {
        var grouped: [String: Accumulator] = [:]

        for row in rows {
            // A row counts only when it has measured usage — a zero-token, zero-cost row is idle, not a
            // model worth listing. (Mirrors cursorcat's rawAPI `hasVisibleUsage`.)
            guard row.tokens.total != 0 || row.imputedCostDollars != 0 else { continue }

            let family = CursorPricing.family(for: row.model)
            let key = family?.id ?? row.model
            let displayName = family?.displayName ?? row.model

            var accumulator = grouped[key] ?? Accumulator(displayName: displayName, isUnpriced: family == nil)
            accumulator.totalTokens += row.tokens.total
            accumulator.totalCostDollars += row.imputedCostDollars

            // A family's spend can split across pricing variants (`gpt-5.5` + `gpt-5.5-fast`); track each
            // raw model so the hover breakdown can show the split. A variant is unpriced when its exact
            // model has no pricing entry.
            var variant = accumulator.variants[row.model]
                ?? VariantAccumulator(isUnpriced: CursorPricing.pricingEntry(for: row.model) == nil)
            variant.totalCostDollars += row.imputedCostDollars
            accumulator.variants[row.model] = variant

            grouped[key] = accumulator
        }

        let sorted = grouped.values
            .map {
                ModelUsageEntry(
                    name: $0.displayName,
                    costDollars: Double(CursorPricing.toCents($0.totalCostDollars)) / 100,
                    tokens: $0.totalTokens,
                    isUnpriced: $0.isUnpriced,
                    variants: variantRows(from: $0.variants)
                )
            }
            .sorted {
                if $0.costDollars != $1.costDollars { return $0.costDollars > $1.costDollars }
                if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        return foldLowSpendTail(sorted)
    }

    /// A family's per-variant rows, cent-snapped and sorted by spend (then name) for the hover breakdown.
    private static func variantRows(from variants: [String: VariantAccumulator]) -> [ModelVariantUsage] {
        variants
            .map { model, acc in
                ModelVariantUsage(
                    name: model,
                    costDollars: Double(CursorPricing.toCents(acc.totalCostDollars)) / 100,
                    isUnpriced: acc.isUnpriced
                )
            }
            .sorted {
                if $0.costDollars != $1.costDollars { return $0.costDollars > $1.costDollars }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Fold the low-spend priced tail into one "Other" row so the leaderboard stays readable: any model
    /// under `tailThresholdFraction` of total spend collapses into a single summed row, pinned LAST as a
    /// catch-all (regardless of its aggregate size). Rules:
    /// - **Unpriced models are never folded** — their cost is unknown, not small, and folding them would
    ///   hide the unknown-model indicator; they stay listed individually.
    /// - **Only buckets 2+ models** — an "Other" standing in for a single model is pointless, so a lone
    ///   tail model is shown as-is.
    /// - **Never buckets everything** — if no model clears the threshold there's nothing to condense
    ///   behind, so the full list is returned unchanged.
    private static func foldLowSpendTail(_ entries: [ModelUsageEntry]) -> [ModelUsageEntry] {
        let totalSpend = entries.reduce(0) { $0 + $1.costDollars }
        guard totalSpend > 0 else { return entries }
        let threshold = totalSpend * tailThresholdFraction

        var kept: [ModelUsageEntry] = []
        var tail: [ModelUsageEntry] = []
        for entry in entries {
            if entry.isUnpriced || entry.costDollars >= threshold {
                kept.append(entry)
            } else {
                tail.append(entry)
            }
        }
        guard tail.count >= 2, !kept.isEmpty else { return entries }

        // "Other" lists the folded families (name + cost) as its breakdown, so hovering it reveals what
        // it stands for — the analogue of a family's per-variant breakdown.
        let other = ModelUsageEntry(
            name: otherRowName,
            costDollars: tail.reduce(0) { $0 + $1.costDollars },
            tokens: tail.reduce(0) { $0 + $1.tokens },
            isUnpriced: false,
            variants: tail.map { ModelVariantUsage(name: $0.name, costDollars: $0.costDollars, isUnpriced: $0.isUnpriced) }
        )
        return kept + [other]
    }
}

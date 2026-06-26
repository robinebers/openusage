import Foundation

/// Per-model token pricing entry. Rates are USD per million tokens.
struct CursorPricingEntry: Sendable {
    let familyID: String
    let familyDisplayName: String
    let inputPerMillion: Double
    let cacheWritePerMillion: Double
    let cacheReadPerMillion: Double
    let outputPerMillion: Double

    init(manifestEntry: CursorModelManifestPricingEntry) {
        self.familyID = manifestEntry.familyID
        self.familyDisplayName = manifestEntry.familyDisplayName
        self.inputPerMillion = manifestEntry.inputPerMillion
        self.cacheWritePerMillion = manifestEntry.cacheWritePerMillion
        self.cacheReadPerMillion = manifestEntry.cacheReadPerMillion
        self.outputPerMillion = manifestEntry.outputPerMillion
    }
}

/// Token counts for a single usage event.
struct CursorTokenUsage: Sendable, Equatable {
    let inputCacheWrite: Int
    let inputNoCacheWrite: Int
    let cacheRead: Int
    let output: Int

    /// All buckets summed — the measured token total shown alongside the cost on a spend tile.
    var total: Int { inputCacheWrite + inputNoCacheWrite + cacheRead + output }
}

enum CursorPricing {
    private static let manifestSource: CursorModelManifestSource = CursorBundledModelManifestSource()
    private static let modelManifest: CursorModelManifest = {
        do {
            return try manifestSource.loadManifest()
        } catch {
            // Loud-fail: an empty manifest silently prices every Cursor spend tile at $0 (every model
            // becomes "unknown"). Surface the packaging/resource failure instead of masquerading
            // damaged data as free usage.
            AppLog.error(LogTag.plugin("cursor"), "pricing manifest load failed; Cursor spend will price at $0: \(error.localizedDescription)")
            return .empty
        }
    }()

    static let manifest: [String: CursorPricingEntry] = modelManifest.pricing.mapValues(CursorPricingEntry.init(manifestEntry:))

    /// Regex → canonical name. Order matters: first match wins. Compiled once.
    private struct AliasRule: @unchecked Sendable {
        let regex: NSRegularExpression
        let canonical: String
    }

    private static let aliasRules: [AliasRule] = {
        modelManifest.aliasRules.compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern))
                .map { AliasRule(regex: $0, canonical: rule.canonical) }
        }
    }()

    static func canonicalModel(for model: String) -> String? {
        let range = NSRange(model.startIndex..<model.endIndex, in: model)
        return aliasRules.first { rule in
            rule.regex.firstMatch(in: model, range: range) != nil
        }?.canonical
    }

    static func pricingEntry(for model: String) -> CursorPricingEntry? {
        guard let canonical = canonicalModel(for: model) else { return nil }
        return manifest[canonical]
    }

    /// A model's family — the group the model leaderboard buckets by, so pricing variants of one
    /// model (e.g. `gpt-5.5` and `gpt-5.5-fast`, which share a `family_id`) collapse into a single
    /// "GPT-5.5" row. `nil` for an unknown/unpriced model, which the caller then keys by its raw id.
    struct ModelFamily: Sendable {
        let id: String
        let displayName: String
    }

    static func family(for model: String) -> ModelFamily? {
        guard let entry = pricingEntry(for: model) else { return nil }
        return ModelFamily(id: entry.familyID, displayName: entry.familyDisplayName)
    }

    /// Estimate the USD cost (dollars, not cents) for one dashboard CSV row.
    ///
    /// Cursor's CSV rows are aggregates, not individual requests, so long-context thresholds and Max
    /// Mode uplift cannot be applied reliably from row totals; we bill at the base model API rate.
    /// Returns 0 for unpriced/unknown models.
    static func estimatedCostDollars(model: String, maxMode _: Bool, tokens: CursorTokenUsage) -> Double {
        guard let entry = pricingEntry(for: model) else { return 0 }
        return Double(tokens.inputCacheWrite) / 1_000_000 * entry.cacheWritePerMillion +
            Double(tokens.inputNoCacheWrite) / 1_000_000 * entry.inputPerMillion +
            Double(tokens.cacheRead) / 1_000_000 * entry.cacheReadPerMillion +
            Double(tokens.output) / 1_000_000 * entry.outputPerMillion
    }

    /// Convert a dollar amount to integer cents, rounded to nearest. Preserves sign. Used to sum many
    /// rows without double-drift before formatting a range total.
    static func toCents(_ dollars: Double) -> Int {
        Int((dollars * 100).rounded())
    }
}

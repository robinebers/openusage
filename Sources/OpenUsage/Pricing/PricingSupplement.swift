import Foundation

/// OpenUsage's own pricing feed: models that no public catalog carries (Cursor-native `auto`,
/// `composer-*`, `github_bugbot`), fast-variant multipliers the catalogs omit, and the alias rules
/// that map provider log/CSV slugs to canonical pricing keys. Ships bundled as
/// `pricing_supplement.json` and refreshes from gh-pages, so entries update without an app release.
struct PricingSupplement: Sendable {
    /// Models priced directly by the supplement (highest-precedence source).
    let pricing: [String: ModelRates]
    /// Base-model -> fast-variant multiplier, for `-fast` slugs whose catalogs carry no `fast` field.
    let fastMultipliers: [String: Double]
    let aliasRules: [AliasRule]
    let updatedAt: String?

    /// Regex slug -> canonical pricing key. Rules apply in order; first match wins.
    struct AliasRule: @unchecked Sendable {
        let pattern: NSRegularExpression
        let canonical: String
    }

    init(
        pricing: [String: ModelRates] = [:],
        fastMultipliers: [String: Double] = [:],
        aliasRules: [AliasRule] = [],
        updatedAt: String? = nil
    ) {
        self.pricing = pricing
        self.fastMultipliers = fastMultipliers
        self.aliasRules = aliasRules
        self.updatedAt = updatedAt
    }

    /// The canonical pricing key for `model` per the alias rules, or nil when no rule matches.
    func canonicalName(for model: String) -> String? {
        let range = NSRange(model.startIndex..., in: model)
        for rule in aliasRules where rule.pattern.firstMatch(in: model, range: range) != nil {
            return rule.canonical
        }
        return nil
    }

    /// Fast multiplier for a resolved base model. Exact key match first, then ccusage's
    /// normalized-suffix matching so dated keys (`gpt-5.5-2026-04-23`) still find their base entry.
    func fastMultiplier(for model: String) -> Double? {
        if let exact = fastMultipliers[model] { return exact }
        let normalized = PricingCatalog.normalizedKey(model)
        for part in normalized.split(whereSeparator: { $0 == "/" || $0 == ":" }) {
            for (base, multiplier) in fastMultipliers {
                if Self.matchesModelSuffix(part: String(part), base: PricingCatalog.normalizedKey(base)) {
                    return multiplier
                }
            }
        }
        return nil
    }

    /// Overlays a fetched supplement on the bundled baseline. Remote base prices and multipliers
    /// win, while newly bundled models, aliases, and long-context metadata remain available to an
    /// upgraded app whose disk cache predates those fields.
    func merging(_ overlay: PricingSupplement) -> PricingSupplement {
        var mergedPricing = pricing
        for (model, overlayRates) in overlay.pricing {
            mergedPricing[model] = overlayRates.fillingMissingLongContext(from: pricing[model])
        }
        var mergedMultipliers = fastMultipliers
        mergedMultipliers.merge(overlay.fastMultipliers) { _, overlay in overlay }

        var seenRules = Set(overlay.aliasRules.map { "\($0.pattern.pattern)\u{0}\($0.canonical)" })
        var mergedRules = overlay.aliasRules
        for rule in aliasRules {
            let key = "\(rule.pattern.pattern)\u{0}\(rule.canonical)"
            if seenRules.insert(key).inserted {
                mergedRules.append(rule)
            }
        }
        return PricingSupplement(
            pricing: mergedPricing,
            fastMultipliers: mergedMultipliers,
            aliasRules: mergedRules,
            updatedAt: overlay.updatedAt ?? updatedAt
        )
    }

    /// `base` occurs in `part` with nothing after it, or followed by a `-` separator.
    private static func matchesModelSuffix(part: String, base: String) -> Bool {
        guard let range = part.range(of: base, options: .backwards) else { return false }
        let suffix = part[range.upperBound...]
        return suffix.isEmpty || suffix.hasPrefix("-")
    }
}

private extension ModelRates {
    func fillingMissingLongContext(from fallback: ModelRates?) -> ModelRates {
        guard let fallback else { return self }
        let hasLongContextRates = inputAbove200kPerMillion != nil
            || outputAbove200kPerMillion != nil
            || cacheWriteAbove200kPerMillion != nil
            || cacheReadAbove200kPerMillion != nil
        guard !hasLongContextRates else { return self }

        var result = self
        result.longContextThresholdTokens = fallback.longContextThresholdTokens
        result.inputAbove200kPerMillion = fallback.inputAbove200kPerMillion
        result.outputAbove200kPerMillion = fallback.outputAbove200kPerMillion
        result.cacheWriteAbove200kPerMillion = fallback.cacheWriteAbove200kPerMillion
        result.cacheReadAbove200kPerMillion = fallback.cacheReadAbove200kPerMillion
        return result
    }
}

// MARK: - JSON decoding

extension PricingSupplement {
    /// Decodes the supplement JSON (bundled resource or the gh-pages feed). Throws on malformed
    /// JSON; individually invalid alias patterns are skipped loudly.
    static func decode(from data: Data) throws -> PricingSupplement {
        let file = try JSONDecoder().decode(SupplementFile.self, from: data)
        var pricing: [String: ModelRates] = [:]
        for (model, entry) in file.pricing {
            if let threshold = entry.longContextThresholdTokens, threshold <= 0 {
                throw PricingSupplementError.invalidLongContextThreshold(model: model, threshold: threshold)
            }
            pricing[model] = ModelRates(
                inputPerMillion: entry.inputPerMillion,
                outputPerMillion: entry.outputPerMillion,
                cacheWritePerMillion: entry.cacheWritePerMillion ?? entry.inputPerMillion,
                cacheReadPerMillion: entry.cacheReadPerMillion ?? entry.inputPerMillion * 0.1,
                longContextThresholdTokens: entry.longContextThresholdTokens ?? 200_000,
                inputAbove200kPerMillion: entry.inputLongContextPerMillion,
                outputAbove200kPerMillion: entry.outputLongContextPerMillion,
                cacheWriteAbove200kPerMillion: entry.cacheWriteLongContextPerMillion,
                cacheReadAbove200kPerMillion: entry.cacheReadLongContextPerMillion,
                cacheReadIsExplicit: entry.cacheReadPerMillion != nil
            )
        }
        var rules: [AliasRule] = []
        for rule in file.aliasRules {
            do {
                let pattern = try NSRegularExpression(pattern: rule.pattern)
                rules.append(AliasRule(pattern: pattern, canonical: rule.canonical))
            } catch {
                AppLog.warn(.cache, "pricing supplement: invalid alias pattern '\(rule.pattern)' skipped: \(error.localizedDescription)")
            }
        }
        return PricingSupplement(
            pricing: pricing,
            fastMultipliers: file.fastMultipliers ?? [:],
            aliasRules: rules,
            updatedAt: file.updatedAt
        )
    }

    private struct SupplementFile: Decodable {
        var updatedAt: String?
        var pricing: [String: Entry]
        var fastMultipliers: [String: Double]?
        var aliasRules: [Rule]

        struct Entry: Decodable {
            var inputPerMillion: Double
            var outputPerMillion: Double
            var cacheWritePerMillion: Double?
            var cacheReadPerMillion: Double?
            var longContextThresholdTokens: Int?
            var inputLongContextPerMillion: Double?
            var outputLongContextPerMillion: Double?
            var cacheWriteLongContextPerMillion: Double?
            var cacheReadLongContextPerMillion: Double?

            enum CodingKeys: String, CodingKey {
                case inputPerMillion = "input_per_million"
                case outputPerMillion = "output_per_million"
                case cacheWritePerMillion = "cache_write_per_million"
                case cacheReadPerMillion = "cache_read_per_million"
                case longContextThresholdTokens = "long_context_threshold_tokens"
                case inputLongContextPerMillion = "input_long_context_per_million"
                case outputLongContextPerMillion = "output_long_context_per_million"
                case cacheWriteLongContextPerMillion = "cache_write_long_context_per_million"
                case cacheReadLongContextPerMillion = "cache_read_long_context_per_million"
            }
        }

        struct Rule: Decodable {
            var pattern: String
            var canonical: String
        }

        enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at"
            case pricing
            case fastMultipliers = "fast_multipliers"
            case aliasRules = "alias_rules"
        }
    }
}


enum PricingSupplementError: Error, LocalizedError, Equatable {
    case invalidLongContextThreshold(model: String, threshold: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidLongContextThreshold(model, threshold):
            return "Pricing supplement model '\(model)' has invalid long-context threshold \(threshold)."
        }
    }
}

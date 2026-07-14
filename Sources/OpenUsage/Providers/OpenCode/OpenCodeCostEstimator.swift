import Foundation

enum OpenCodeProviderIDs {
    static let hosted: Set<String> = ["opencode-go", "opencode"]
    static let go = "opencode-go"
}

enum OpenCodeCostResolution: Sendable, Equatable {
    case priced(tokens: Int, cost: Double, model: String)
    case unpriced(model: String)
    case ignored
}

protocol OpenCodeCostEstimating: Sendable {
    func resolve(row: OpenCodeUsageRow, pricing: ModelPricing) -> OpenCodeCostResolution
}

/// Owns OpenCode's accounting policy independently of SQLite and UI concerns. Hosted rows trust a
/// valid recorded value (including zero); external positive values stay authoritative; and external
/// zero/missing values are estimated only when their non-overlapping token buckets can be priced.
struct OpenCodeCostEstimator: OpenCodeCostEstimating {
    func resolve(row: OpenCodeUsageRow, pricing: ModelPricing) -> OpenCodeCostResolution {
        let displayModel = Self.displayModel(for: row)

        // A malformed external value is not the same as an absent/zero subscription cost. Exclude it
        // loudly instead of replacing corrupted accounting with an apparently valid catalog estimate.
        if row.hasInvalidRecordedCost {
            return row.tokens > 0 ? .unpriced(model: displayModel) : .ignored
        }

        if OpenCodeProviderIDs.hosted.contains(row.providerID) {
            if let recordedCost = row.recordedCost {
                return .priced(tokens: row.tokens, cost: recordedCost, model: displayModel)
            }
            return row.tokens > 0 ? .unpriced(model: displayModel) : .ignored
        }

        if let recordedCost = row.recordedCost, recordedCost > 0 {
            return .priced(tokens: row.tokens, cost: recordedCost, model: displayModel)
        }

        // Total-only records cannot be honestly split across rates. Keep tokens and dollars aligned by
        // excluding them together and surfacing the model as unpriced.
        guard row.bucketTokens > 0 else {
            return row.tokens > 0 ? .unpriced(model: displayModel) : .ignored
        }

        let tokens = TokenBreakdown(
            input: row.input,
            cacheWrite5m: row.cacheWrite,
            cacheRead: row.cacheRead,
            output: row.output + row.reasoning
        )
        guard let cost = Self.estimatedCost(
            providerID: row.providerID,
            model: row.model,
            tokens: tokens,
            pricing: pricing
        ) else {
            return row.tokens > 0 ? .unpriced(model: displayModel) : .ignored
        }
        return .priced(tokens: row.tokens, cost: cost, model: displayModel)
    }

    private static func displayModel(for row: OpenCodeUsageRow) -> String {
        let model = row.model.isEmpty ? ModelUsageEntry.unattributedModelName : row.model
        return OpenCodeProviderIDs.hosted.contains(row.providerID) ? model : "\(row.providerID)/\(model)"
    }

    /// Prefer provider-qualified exact matches, then bare exact matches, before allowing bare fuzzy
    /// lookup. Reseller-specific rates stay authoritative without an unrelated qualified fuzzy key
    /// shadowing a known bare model.
    private static func estimatedCost(
        providerID: String,
        model: String,
        tokens: TokenBreakdown,
        pricing: ModelPricing
    ) -> Double? {
        let models = pricingModelCandidates(model)
        let normalizedProvider = providerID.replacingOccurrences(of: "-", with: "_")
        var qualified = ["\(providerID)/\(model)"]
        for candidate in models where candidate != model {
            qualified.append("\(providerID)/\(candidate)")
        }
        if normalizedProvider != providerID {
            qualified.append("\(normalizedProvider)/\(model)")
            for candidate in models where candidate != model {
                qualified.append("\(normalizedProvider)/\(candidate)")
            }
        }

        for candidate in unique(qualified) {
            if let cost = pricing.estimatedCostDollarsExact(model: candidate, tokens: tokens) {
                return cost
            }
        }
        for candidate in models {
            if let cost = pricing.estimatedCostDollarsExact(model: candidate, tokens: tokens) {
                return cost
            }
        }
        for candidate in models {
            if let cost = pricing.estimatedCostDollars(model: candidate, tokens: tokens) {
                return cost
            }
        }
        return nil
    }

    /// OpenCode emits a few provider/model spellings that differ from public catalog keys. These
    /// compatibility candidates are deliberately provider-local; shared aliases still resolve inside
    /// `ModelPricing` before catalog lookup.
    private static func pricingModelCandidates(_ model: String) -> [String] {
        let normalized: String = switch model {
        case "k2p6": "kimi-k2.6"
        case "gemini-3-pro-high": "gemini-3-pro-preview"
        default: normalizedClaudeModel(model)
        }
        return unique([normalized, model])
    }

    private static func normalizedClaudeModel(_ model: String) -> String {
        let prefixes = ["claude-haiku-", "claude-opus-", "claude-sonnet-"]
        guard let prefix = prefixes.first(where: model.hasPrefix) else { return model }
        let suffix = String(model.dropFirst(prefix.count))
        let characters = Array(suffix)
        guard characters.count >= 2, characters[0].isNumber else { return model }

        if characters.count >= 3, characters[1] == ".", characters[2].isNumber {
            return prefix + String(characters[0]) + "-" + String(characters.dropFirst(2))
        }
        if characters[1].isNumber, characters.count == 2 || characters[2] == "-" {
            return prefix + String(characters[0]) + "-" + String(characters.dropFirst())
        }
        return model
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

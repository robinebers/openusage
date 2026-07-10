import Foundation

/// Parsers for the two public pricing feeds, plus the compact catalog format OpenUsage uses for
/// its bundled snapshots and on-disk caches (cost fields only — the full feeds are megabytes).
enum PricingCatalogCodecs {
    // MARK: - LiteLLM (model_prices_and_context_window.json)

    /// Builds a catalog from LiteLLM's full JSON. Entries without both input and output costs are
    /// skipped (stubs and non-chat modes). Costs are per-token in the feed; stored per-million.
    /// Parsed with JSONSerialization so one malformed entry can't sink the whole feed.
    static func catalogFromLiteLLM(_ data: Data) throws -> PricingCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingCodecError.notAnObject
        }
        var entries: [String: ModelRates] = [:]
        for (key, value) in root {
            guard let entry = value as? [String: Any],
                  let input = doubleValue(entry["input_cost_per_token"]),
                  let output = doubleValue(entry["output_cost_per_token"]) else { continue }
            let cacheWrite = doubleValue(entry["cache_creation_input_token_cost"])
            let cacheRead = doubleValue(entry["cache_read_input_token_cost"])
            var rates = ModelRates(
                inputPerMillion: input * 1_000_000,
                outputPerMillion: output * 1_000_000,
                cacheWritePerMillion: (cacheWrite ?? input) * 1_000_000,
                cacheReadPerMillion: (cacheRead ?? input * 0.1) * 1_000_000
            )
            rates.inputAbove200kPerMillion = doubleValue(entry["input_cost_per_token_above_200k_tokens"]).map { $0 * 1_000_000 }
            rates.outputAbove200kPerMillion = doubleValue(entry["output_cost_per_token_above_200k_tokens"]).map { $0 * 1_000_000 }
            rates.cacheWriteAbove200kPerMillion = doubleValue(entry["cache_creation_input_token_cost_above_200k_tokens"]).map { $0 * 1_000_000 }
            rates.cacheReadAbove200kPerMillion = doubleValue(entry["cache_read_input_token_cost_above_200k_tokens"]).map { $0 * 1_000_000 }
            if let providerSpecific = entry["provider_specific_entry"] as? [String: Any],
               let fast = doubleValue(providerSpecific["fast"]) {
                rates.fastMultiplier = fast
            }
            entries[key] = rates
        }
        guard !entries.isEmpty else { throw PricingCodecError.noUsableEntries }
        return PricingCatalog(entries: entries)
    }

    // MARK: - models.dev (api.json)

    /// Builds a catalog from models.dev's api.json (`{provider: {models: {id: {cost: ...}}}}`).
    /// Model ids are stored bare; when the same id appears under several providers the first in
    /// provider-name order wins (rates agree in practice). Costs are already per-million.
    static func catalogFromModelsDev(_ data: Data) throws -> PricingCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingCodecError.notAnObject
        }
        var entries: [String: ModelRates] = [:]
        for providerName in root.keys.sorted() {
            guard let provider = root[providerName] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            for (modelID, value) in models {
                guard entries[modelID] == nil,
                      let model = value as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = doubleValue(cost["input"]),
                      let output = doubleValue(cost["output"]) else { continue }
                entries[modelID] = ModelRates(
                    inputPerMillion: input,
                    outputPerMillion: output,
                    cacheWritePerMillion: doubleValue(cost["cache_write"]) ?? input,
                    cacheReadPerMillion: doubleValue(cost["cache_read"]) ?? input * 0.1
                )
            }
        }
        guard !entries.isEmpty else { throw PricingCodecError.noUsableEntries }
        return PricingCatalog(entries: entries)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    // MARK: - Compact format (bundled snapshots + disk cache)

    static func catalogFromCompact(_ data: Data) throws -> PricingCatalog {
        let file = try JSONDecoder().decode(CompactCatalog.self, from: data)
        var entries: [String: ModelRates] = [:]
        entries.reserveCapacity(file.models.count)
        for (key, model) in file.models {
            entries[key] = ModelRates(
                inputPerMillion: model.i,
                outputPerMillion: model.o,
                cacheWritePerMillion: model.cw,
                cacheReadPerMillion: model.cr,
                inputAbove200kPerMillion: model.ia,
                outputAbove200kPerMillion: model.oa,
                cacheWriteAbove200kPerMillion: model.cwa,
                cacheReadAbove200kPerMillion: model.cra,
                fastMultiplier: model.fast ?? 1
            )
        }
        return PricingCatalog(entries: entries, retrievedAt: file.retrievedAt)
    }

    static func compactData(from catalog: PricingCatalog) throws -> Data {
        var models: [String: CompactCatalog.Model] = [:]
        models.reserveCapacity(catalog.entries.count)
        for (key, rates) in catalog.entries {
            models[key] = CompactCatalog.Model(
                i: rates.inputPerMillion,
                o: rates.outputPerMillion,
                cw: rates.cacheWritePerMillion,
                cr: rates.cacheReadPerMillion,
                ia: rates.inputAbove200kPerMillion,
                oa: rates.outputAbove200kPerMillion,
                cwa: rates.cacheWriteAbove200kPerMillion,
                cra: rates.cacheReadAbove200kPerMillion,
                fast: rates.fastMultiplier == 1 ? nil : rates.fastMultiplier
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(CompactCatalog(retrievedAt: catalog.retrievedAt, models: models))
    }

    /// Per-million rates keyed by short names to keep snapshots small: `i`nput, `o`utput,
    /// `c`ache`w`rite, `c`ache`r`ead, with `a`bove-200k variants, plus the `fast` multiplier.
    private struct CompactCatalog: Codable {
        var retrievedAt: String?
        var models: [String: Model]

        struct Model: Codable {
            var i: Double
            var o: Double
            var cw: Double
            var cr: Double
            var ia: Double?
            var oa: Double?
            var cwa: Double?
            var cra: Double?
            var fast: Double?
        }

        enum CodingKeys: String, CodingKey {
            case retrievedAt = "retrieved_at"
            case models
        }
    }
}

enum PricingCodecError: Error, LocalizedError, Equatable {
    case notAnObject
    case noUsableEntries

    var errorDescription: String? {
        switch self {
        case .notAnObject: return "Pricing feed is not a JSON object."
        case .noUsableEntries: return "Pricing feed contained no usable model entries."
        }
    }
}

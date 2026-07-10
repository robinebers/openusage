import Foundation

/// Per-million-token USD rates for one model, plus optional long-context tiers and a fast-variant
/// multiplier. All spend imputation (Claude, Codex, Cursor, Grok) prices through these.
struct ModelRates: Sendable, Equatable {
    var inputPerMillion: Double
    var outputPerMillion: Double
    /// 5-minute ephemeral cache writes (Anthropic-style). For providers without a separate
    /// cache-write price this equals the input rate.
    var cacheWritePerMillion: Double
    var cacheReadPerMillion: Double

    /// Rates for requests whose prompt exceeds 200k tokens, where the provider prices the whole
    /// request at the higher long-context tier.
    var inputAbove200kPerMillion: Double?
    var outputAbove200kPerMillion: Double?
    var cacheWriteAbove200kPerMillion: Double?
    var cacheReadAbove200kPerMillion: Double?

    /// Rate multiplier for the model's "fast" variant (1 when the model has none).
    var fastMultiplier: Double = 1

    /// The same rates with every dollar figure scaled — used to price `-fast` model slugs off their
    /// base entry.
    func scaled(by factor: Double) -> ModelRates {
        ModelRates(
            inputPerMillion: inputPerMillion * factor,
            outputPerMillion: outputPerMillion * factor,
            cacheWritePerMillion: cacheWritePerMillion * factor,
            cacheReadPerMillion: cacheReadPerMillion * factor,
            inputAbove200kPerMillion: inputAbove200kPerMillion.map { $0 * factor },
            outputAbove200kPerMillion: outputAbove200kPerMillion.map { $0 * factor },
            cacheWriteAbove200kPerMillion: cacheWriteAbove200kPerMillion.map { $0 * factor },
            cacheReadAbove200kPerMillion: cacheReadAbove200kPerMillion.map { $0 * factor },
            fastMultiplier: 1
        )
    }
}

/// Token counts split into the buckets that price differently. Every scanner normalizes into this.
struct TokenBreakdown: Sendable, Equatable {
    /// Input tokens billed at the plain input rate (not written to or read from cache).
    var input: Int = 0
    /// Input tokens written to the 5-minute ephemeral cache.
    var cacheWrite5m: Int = 0
    /// Input tokens written to the 1-hour ephemeral cache (billed at 2x input).
    var cacheWrite1h: Int = 0
    var cacheRead: Int = 0
    var output: Int = 0
    /// The request ran the model's "fast" variant (Claude logs carry a `speed` field).
    var isFast: Bool = false

    /// Input that determines whether the request crosses the long-context threshold. Output does not
    /// select the tier, but it is billed at the selected tier once the prompt crosses the threshold.
    var promptTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
    var totalTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
}

extension ModelRates {
    /// 1-hour cache writes are billed at twice the input rate (ccusage's rule; matches LiteLLM's
    /// explicit `above_1hr` fields where present).
    private static let cacheWrite1hInputMultiplier = 2.0

    /// Dollar cost of one request at these rates, applying the request-wide >200k tier and the fast
    /// multiplier. Aggregated sources can opt out when their totals do not preserve request boundaries.
    func costDollars(for tokens: TokenBreakdown, applyLongContextRates: Bool = true) -> Double {
        let multiplier = tokens.isFast ? fastMultiplier : 1
        let useLongContextRates = applyLongContextRates && tokens.promptTokens > 200_000
        let inputRate = selectedRate(base: inputPerMillion, longContext: inputAbove200kPerMillion,
                                     useLongContextRates: useLongContextRates)
        let outputRate = selectedRate(base: outputPerMillion, longContext: outputAbove200kPerMillion,
                                      useLongContextRates: useLongContextRates)
        let cacheWriteRate = selectedRate(base: cacheWritePerMillion, longContext: cacheWriteAbove200kPerMillion,
                                          useLongContextRates: useLongContextRates)
        let cacheReadRate = selectedRate(base: cacheReadPerMillion, longContext: cacheReadAbove200kPerMillion,
                                         useLongContextRates: useLongContextRates)
        let cacheWrite1hRate = selectedRate(
            base: inputPerMillion,
            longContext: inputAbove200kPerMillion,
            useLongContextRates: useLongContextRates
        ) * Self.cacheWrite1hInputMultiplier

        let cost = cost(tokens.input, at: inputRate)
            + cost(tokens.output, at: outputRate)
            + cost(tokens.cacheWrite5m, at: cacheWriteRate)
            + cost(tokens.cacheWrite1h, at: cacheWrite1hRate)
            + cost(tokens.cacheRead, at: cacheReadRate)
        return cost * multiplier
    }

    private func selectedRate(base: Double, longContext: Double?, useLongContextRates: Bool) -> Double {
        useLongContextRates ? (longContext ?? base) : base
    }

    private func cost(_ tokens: Int, at ratePerMillion: Double) -> Double {
        Double(tokens) * ratePerMillion / 1_000_000
    }
}

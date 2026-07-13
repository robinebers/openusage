import Foundation

/// Accumulates priced per-day usage — tokens, cost, and the per-model breakdown — then assembles a
/// `LogUsageScan`. Shared by the log scanners (Claude, Codex, Grok) so the "accumulate then assemble"
/// tail lives in one place instead of a byte-identical copy per provider; each scanner keeps only its
/// format-specific parse/pricing loop.
///
/// Days are keyed by the shared local-calendar `dayKey`, matching `SpendTileMapper`'s Today / Yesterday
/// lookup — the day-key contract is one function, not five copies (drift here is the class of bug behind
/// the ccusage false-zero fix). Only priced rows are added (every scanner skips unpriceable rows before
/// counting), so every counted day carries a real cost; unpriceable models are tracked separately for
/// the tile's warning triangle.
struct DailyUsageAccumulator {
    private var tokensByDay: [String: Int] = [:]
    private var costByDay: [String: Double] = [:]
    private var unknownModelsByDay: [String: Set<String>] = [:]
    private var modelsByDay: [String: [String: ModelAccumulator]] = [:]

    /// Local calendar day as `yyyy-MM-dd`. The single day-key contract shared by the accumulator,
    /// `SpendTileMapper`, and the Cursor CSV aggregation. `calendar` is injectable for tests; production
    /// uses `.current`.
    static func dayKey(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Add a priced row's tokens + cost, attributed to `model` on `day`.
    mutating func add(day: String, tokens: Int, cost: Double, model: String) {
        tokensByDay[day, default: 0] += tokens
        costByDay[day, default: 0] += cost
        modelsByDay[day, default: [:]][model, default: ModelAccumulator()].add(tokens: tokens, costUSD: cost)
    }

    /// Merge already-built scans (a provider's native log scan plus its pi slice) into one, by replaying
    /// each scan's per-model daily usage through a fresh accumulator so the combined `series`,
    /// `modelUsage`, and unknown-model set stay consistent. Every input must be accumulator-built (its
    /// `series` derived from the same per-model maps), which the native and pi scanners guarantee. Nil
    /// inputs are skipped; returns nil when they are all nil (the provider then folds in nothing).
    static func merged(_ scans: [LogUsageScan?]) -> LogUsageScan? {
        let present = scans.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        var accumulator = DailyUsageAccumulator()
        for scan in present {
            for day in scan.modelUsage?.daily ?? [] {
                for model in day.models {
                    // Skip cost-unknown entries rather than treating nil as $0 — their unknown-model
                    // metadata is already carried through via unknownModelsByDay below.
                    guard let cost = model.costUSD else { continue }
                    accumulator.add(day: day.date, tokens: model.totalTokens, cost: cost, model: model.model)
                }
            }
            for (day, models) in scan.unknownModelsByDay {
                for model in models {
                    accumulator.addUnknownModel(day: day, model: model)
                }
            }
        }
        return accumulator.build()
    }

    /// Note a model that couldn't be priced but still carried tokens — surfaced as the tile's warning
    /// triangle, the only place unpriceable usage appears (it's excluded from every displayed total).
    mutating func addUnknownModel(day: String, model: String) {
        unknownModelsByDay[day, default: []].insert(model)
    }

    /// Assemble the scan: per-day tokens/cost (days sorted newest-first), the per-day model breakdown,
    /// and the unknown-model set. Every counted day is priced, so its `costUSD` is always the real total.
    func build() -> LogUsageScan {
        let days = tokensByDay.keys.sorted(by: >).map { day in
            DailyUsageEntry(date: day, totalTokens: tokensByDay[day] ?? 0, costUSD: costByDay[day] ?? 0)
        }
        let modelUsage = ModelUsageSeries(daily: modelsByDay.keys.sorted(by: >).map { day in
            DailyModelUsageEntry(
                date: day,
                models: modelsByDay[day, default: [:]].map { model, accumulator in accumulator.entry(model: model) }
            )
        })
        return LogUsageScan(
            series: DailyUsageSeries(daily: days),
            modelUsage: modelUsage,
            unknownModelsByDay: unknownModelsByDay
        )
    }

    private struct ModelAccumulator {
        var tokens = 0
        var costUSD: Double?

        mutating func add(tokens: Int, costUSD: Double?) {
            self.tokens += tokens
            if let costUSD {
                self.costUSD = (self.costUSD ?? 0) + costUSD
            }
        }

        func entry(model: String) -> ModelUsageEntry {
            ModelUsageEntry(model: model, totalTokens: tokens, costUSD: costUSD)
        }
    }
}

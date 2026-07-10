import Foundation

/// Turns local daily token/cost data into the shared Today / Yesterday / Last 30 Days spend tiles.
/// Every spend-tracking provider funnels through here so the tiles render identically regardless of
/// source: Claude / Codex / Grok feed token/cost from their CLI logs, while Cursor feeds token/cost
/// derived from its CSV export. The data shape
/// (`DailyUsageSeries`) is a provider-neutral per-day carrier shared by every source.
enum SpendTileMapper {
    /// Append the three spend tiles (Today / Yesterday / Last 30 Days). A period with no usage is left
    /// unbacked so the tile reads "No data" — a zero here is indistinguishable from "the source hasn't
    /// accounted for this day yet," and a confident `$0.00 · 0 tokens` contradicts a live session meter
    /// that proves otherwise. This holds for every source (the Claude/Codex/Grok log scanners,
    /// Cursor's CSV export); there's no per-source branching. "No data" is also what a tile shows when
    /// the source couldn't be read at all (missing log, failed API/CSV), where the caller appends
    /// nothing. `estimated` controls whether the dollar value carries the local-estimate marker (ⓘ).
    /// `unknownModelsByDay` maps a `yyyy-MM-dd` day key to the set of model names used that day that no
    /// pricing source can price. Today / Yesterday pick up their own day's set; Last 30 Days carries the
    /// union across the whole window. Empty (the default) for sources without unknown-model detection, so
    /// their tiles never carry unknown-model warnings.
    static func appendTokenUsage(
        _ usage: DailyUsageSeries,
        to lines: inout [MetricLine],
        now: Date = Date(),
        estimated: Bool = true,
        unknownModelsByDay: [String: Set<String>] = [:],
        modelUsage: ModelUsageSeries? = nil,
        modelSourceNote: String? = nil
    ) {
        let today = dayKey(from: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now).map(dayKey(from:))

        if let entry = usage.daily.first(where: { dayKey(fromUsageDate: $0.date) == today }), hasUsage(entry) {
            lines.append(dayUsageLine(label: "Today", entry: entry, estimated: estimated,
                                      unknownModels: sortedModels(unknownModelsByDay[today]),
                                      modelBreakdown: modelBreakdown(
                                        modelUsage,
                                        days: [today],
                                        totalTokens: entry.totalTokens,
                                        totalCostUSD: entry.costUSD,
                                        sourceNote: modelSourceNote
                                      )))
        }
        if let entry = usage.daily.first(where: { dayKey(fromUsageDate: $0.date) == yesterday }), hasUsage(entry) {
            lines.append(dayUsageLine(label: "Yesterday", entry: entry, estimated: estimated,
                                      unknownModels: sortedModels(yesterday.flatMap { unknownModelsByDay[$0] }),
                                      modelBreakdown: modelBreakdown(
                                        modelUsage,
                                        days: Set([yesterday].compactMap { $0 }),
                                        totalTokens: entry.totalTokens,
                                        totalCostUSD: entry.costUSD,
                                        sourceNote: modelSourceNote
                                      )))
        }

        let totalTokens = usage.daily.reduce(0) { $0 + $1.totalTokens }
        let costSamples = usage.daily.compactMap(\.costUSD)
        let totalCost = costSamples.isEmpty ? nil : costSamples.reduce(0, +)
        if totalTokens > 0 || (totalCost ?? 0) > 0 {
            let allUnknown = unknownModelsByDay.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            lines.append(.values(label: "Last 30 Days",
                                 values: spendValues(tokens: totalTokens, costUSD: totalCost, estimated: estimated),
                                 unknownModels: sortedModels(allUnknown),
                                 modelBreakdown: modelBreakdown(
                                    modelUsage,
                                    days: Set(usage.daily.compactMap { dayKey(fromUsageDate: $0.date) }),
                                    totalTokens: totalTokens,
                                    totalCostUSD: totalCost,
                                    sourceNote: modelSourceNote
                                 )))
        }
    }

    /// A period with any real usage: tokens used, dollars priced, or both. A zero-token, zero-cost day
    /// is idle and gets no tile (→ "No data"), not a fabricated `$0.00 · 0 tokens`.
    private static func hasUsage(_ entry: DailyUsageEntry) -> Bool {
        entry.totalTokens > 0 || (entry.costUSD ?? 0) > 0
    }

    /// Number of days before `now` the trend window spans; with `now` itself that's 31 calendar bars,
    /// matching the scanners' `daysBack: 30` query window the daily rows come from.
    private static let trendWindowDays = 30

    /// Append the Usage Trend chart line: one bar per calendar day over the window, value = tokens used
    /// that day. Tokens are always measured (no estimate flag), so the chart needs only the per-day
    /// counts plus a source note. Appends nothing when the whole window is idle, so a source with no
    /// usage leaves "No data" rather than a flat row of zero bars.
    static func appendUsageTrend(_ usage: DailyUsageSeries, to lines: inout [MetricLine], now: Date = Date(), note: String) {
        let points = trendPoints(usage, now: now)
        guard !points.isEmpty else { return }
        lines.append(.chart(label: "Usage Trend", points: points, note: note))
    }

    /// Per-day token points across the queried window (today + the previous 30 days), oldest first.
    /// Tokens are summed per calendar day, so two source rows that normalize to the same date (mixed
    /// formats) become one bar carrying their total rather than two bars splitting it. Idle days are
    /// zero-filled, not dropped, so the sparkline stays calendar-true: a gap shows as a short bar in
    /// place instead of collapsing two non-adjacent days into neighbors, and the cap is calendar days,
    /// not active ones. Returns empty when nothing was used in the window — there's no trend to draw.
    /// Each point carries a "Jun 21" axis label and a pre-formatted "222M tokens" readout.
    private static func trendPoints(_ usage: DailyUsageSeries, now: Date) -> [MetricChartPoint] {
        var tokensByDay: [String: Double] = [:]
        for day in usage.daily {
            let tokens = Double(day.totalTokens)
            guard tokens.isFinite, tokens >= 0, let key = dayKey(fromUsageDate: day.date) else { continue }
            tokensByDay[key, default: 0] += tokens
        }
        guard tokensByDay.values.contains(where: { $0 > 0 }) else { return [] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0...trendWindowDays).reversed().compactMap { offset -> MetricChartPoint? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = dayKey(from: day)
            let tokens = tokensByDay[key] ?? 0
            return MetricChartPoint(
                value: tokens,
                // The app's localized "Jun 21" month/day, not a hardcoded "6/21".
                label: Formatters.monthDayLabel(day),
                valueLabel: MetricFormatter.number(tokens, kind: .count, style: .row) + " tokens"
            )
        }
    }

    private static func dayKey(from date: Date) -> String {
        DailyUsageAccumulator.dayKey(from: date)
    }

    private static func dayKey(fromUsageDate rawDate: String) -> String? {
        let value = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return value
        }

        if let date = OpenUsageISO8601.date(from: value) {
            return dayKey(from: date)
        }

        if let match = value.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(value[match])
        }
        if value.range(of: #"^\d{8}$"#, options: .regularExpression) != nil {
            let year = value.prefix(4)
            let month = value.dropFirst(4).prefix(2)
            let day = value.suffix(2)
            return "\(year)-\(month)-\(day)"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd, yyyy"
        if let date = formatter.date(from: value) {
            return dayKey(from: date)
        }

        return nil
    }

    private static func dayUsageLine(
        label: String,
        entry: DailyUsageEntry,
        estimated: Bool,
        unknownModels: [String],
        modelBreakdown: ModelUsageBreakdown?
    ) -> MetricLine {
        .values(label: label, values: spendValues(tokens: entry.totalTokens, costUSD: entry.costUSD, estimated: estimated),
                unknownModels: unknownModels, modelBreakdown: modelBreakdown)
    }

    /// Stable, de-duplicated display order for a period's unknown-model names (the set is unordered).
    private static func sortedModels(_ models: Set<String>?) -> [String] {
        (models ?? []).sorted()
    }

    /// One period's spend as raw values: the estimated dollars followed by the measured token count,
    /// rendered combined as "$4.08 · 1.2M tokens". The token value carries the "tokens" unit (the same
    /// way Codex credits carry "credits"), so the three spend tiles read consistently.
    ///
    /// Only called for a period with real usage (see `hasUsage`). Some token-only callers may not provide
    /// a dollar value. `estimated` flags locally calculated dollars with the ⓘ; token counts are always
    /// measured, never flagged.
    private static func spendValues(tokens: Int, costUSD: Double?, estimated: Bool) -> [MetricValue] {
        var values: [MetricValue] = []
        if let costUSD {
            values.append(MetricValue(number: costUSD, kind: .dollars, estimated: estimated))
        }
        values.append(MetricValue(number: Double(tokens), kind: .count, label: "tokens"))
        return values
    }

    private static let namedModelCap = 5

    /// Tracks the casings seen for one case-folded name and elects the one that carried the most
    /// tokens (ties prefer the all-lowercase spelling, then alphabetical) — so `GLM-5.2` and `glm-5.2`
    /// collapse into one row titled with whichever spelling dominated the period.
    private struct SpellingVote {
        private var tokensBySpelling: [String: Int] = [:]

        mutating func note(_ spelling: String, weight: Int) {
            // Zero-token entries (cost-only lines) still get a say.
            tokensBySpelling[spelling, default: 0] += max(weight, 1)
        }

        var best: String? {
            tokensBySpelling.min { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                let lhsLower = lhs.key == lhs.key.lowercased()
                let rhsLower = rhs.key == rhs.key.lowercased()
                if lhsLower != rhsLower { return lhsLower }
                return lhs.key < rhs.key
            }?.key
        }
    }

    private struct ModelAccumulator {
        var tokens = 0
        var costUSD: Double?
        private var nameVote = SpellingVote()
        /// Keyed by the case-folded slug; the vote inside restores a display spelling.
        private var variants: [String: (tokens: Int, costUSD: Double?, vote: SpellingVote)] = [:]

        /// The display spelling for this model, elected across every casing that merged into it.
        var displayName: String? { nameVote.best }

        /// Merge a same-model day entry: variants (raw slugs) merge line-by-line so a multi-day period
        /// keeps one line per slug.
        mutating func add(_ entry: ModelUsageEntry, spelledAs name: String) {
            addTotals(of: entry, spelledAs: name)
            for variant in entry.variants ?? [ModelUsageVariant(model: name, totalTokens: entry.totalTokens, costUSD: entry.costUSD)] {
                mergeVariant(variant.model, tokens: variant.totalTokens, costUSD: variant.costUSD)
            }
        }

        /// Fold a different model into this accumulator (the Other row): one variant per folded model —
        /// its tooltip lists models, not their raw effort slugs. The Other row's own name is fixed, so
        /// folded spellings only vote inside the variant lines.
        mutating func fold(_ entry: ModelUsageEntry) {
            tokens += entry.totalTokens
            if let cost = entry.costUSD {
                costUSD = (costUSD ?? 0) + cost
            }
            mergeVariant(entry.model, tokens: entry.totalTokens, costUSD: entry.costUSD)
        }

        private mutating func addTotals(of entry: ModelUsageEntry, spelledAs name: String) {
            tokens += entry.totalTokens
            if let cost = entry.costUSD {
                costUSD = (costUSD ?? 0) + cost
            }
            nameVote.note(name, weight: entry.totalTokens)
        }

        private mutating func mergeVariant(_ model: String, tokens: Int, costUSD: Double?) {
            let key = model.lowercased()
            var existing = variants[key] ?? (0, nil, SpellingVote())
            existing.tokens += tokens
            existing.costUSD = costUSD.map { (existing.costUSD ?? 0) + $0 } ?? existing.costUSD
            existing.vote.note(model, weight: tokens)
            variants[key] = existing
        }

        func entry(model: String) -> ModelUsageEntry {
            let list = variants
                .map { key, value in
                    ModelUsageVariant(model: value.vote.best ?? key, totalTokens: value.tokens,
                                      costUSD: value.costUSD.map(SpendTileMapper.roundToCents))
                }
                .sorted(by: variantSortPrecedes)
            // One variant carrying the row's own name is no breakdown — nil keeps the tooltip on plain figures.
            let isTrivial = list.count == 1 && list[0].model.lowercased() == model.lowercased()
            return ModelUsageEntry(model: model, totalTokens: tokens,
                                   costUSD: costUSD.map(SpendTileMapper.roundToCents),
                                   variants: isTrivial ? nil : list)
        }
    }

    private static func variantSortPrecedes(_ lhs: ModelUsageVariant, _ rhs: ModelUsageVariant) -> Bool {
        let lhsCost = lhs.costUSD ?? 0
        let rhsCost = rhs.costUSD ?? 0
        if lhsCost != rhsCost { return lhsCost > rhsCost }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
    }

    private static func modelBreakdown(
        _ usage: ModelUsageSeries?,
        days: Set<String>,
        totalTokens: Int,
        totalCostUSD: Double?,
        sourceNote: String?
    ) -> ModelUsageBreakdown? {
        guard let usage, let sourceNote, !days.isEmpty else { return nil }

        // Keyed by the case-folded name so `GLM-5.2` and `glm-5.2` land in one row; the accumulator's
        // spelling vote decides which casing titles it.
        var byModel: [String: ModelAccumulator] = [:]
        for day in usage.daily where dayKey(fromUsageDate: day.date).map(days.contains) == true {
            for model in day.models where model.totalTokens > 0 || (model.costUSD ?? 0) > 0 {
                let name = normalizedModelName(model.model)
                byModel[name.lowercased(), default: ModelAccumulator()].add(model, spelledAs: name)
            }
        }

        let sorted = byModel.map { key, accumulator in accumulator.entry(model: accumulator.displayName ?? key) }
            .sorted(by: modelSortPrecedes)
        let folded = foldModelList(sorted)
        guard !folded.isEmpty else { return nil }
        return ModelUsageBreakdown(
            totalTokens: totalTokens,
            totalCostUSD: totalCostUSD,
            models: folded,
            sourceNote: sourceNote
        )
    }

    private static func normalizedModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ModelUsageEntry.unattributedModelName : trimmed
    }

    private static func modelSortPrecedes(_ lhs: ModelUsageEntry, _ rhs: ModelUsageEntry) -> Bool {
        let lhsCost = lhs.costUSD ?? 0
        let rhsCost = rhs.costUSD ?? 0
        if lhsCost != rhsCost { return lhsCost > rhsCost }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
    }

    /// Models below this share of the period fold into Other regardless of rank — a stack of sub-5%
    /// slivers is noise, and Other's tooltip still names them.
    private static let minVisibleShare = 0.05

    private static func foldModelList(_ entries: [ModelUsageEntry]) -> [ModelUsageEntry] {
        // The threshold must use the same basis the panel's percent labels use (cost shares only when
        // every model is priced, token shares otherwise — see `ModelUsageDetail.share`), or a folded
        // model could have displayed as 5%+.
        let allPriced = entries.allSatisfy { $0.costUSD != nil }
        let costTotal = entries.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
        let tokenTotal = entries.reduce(0) { $0 + $1.totalTokens }
        func share(_ entry: ModelUsageEntry) -> Double {
            if allPriced, costTotal > 0 { return (entry.costUSD ?? 0) / costTotal }
            guard tokenTotal > 0 else { return 0 }
            return Double(entry.totalTokens) / Double(tokenTotal)
        }

        var visible: [ModelUsageEntry] = []
        var other = ModelAccumulator()
        var namedCount = 0

        for entry in entries {
            // Tokens the logs couldn't tie to a model (Grok) read as noise under their own
            // "Unattributed" row — the panel is an insight, not an accounting ledger, so they just
            // count into Other however large they are.
            let isUnattributed = entry.model.caseInsensitiveCompare(ModelUsageEntry.unattributedModelName) == .orderedSame
            if isUnattributed || share(entry) < minVisibleShare {
                other.fold(entry)
            } else if entry.costUSD == nil {
                visible.append(entry)
                namedCount += 1
            } else if namedCount < namedModelCap {
                visible.append(entry)
                namedCount += 1
            } else {
                other.fold(entry)
            }
        }

        if other.tokens > 0 || (other.costUSD ?? 0) > 0 {
            visible.append(other.entry(model: ModelUsageEntry.otherModelName))
        }
        return visible
    }

    private static func roundToCents(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

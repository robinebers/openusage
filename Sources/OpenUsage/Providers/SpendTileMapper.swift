import Foundation

/// Turns local daily token/cost data into the shared Today / Yesterday / Last 30 Days spend tiles.
/// Every spend-tracking provider funnels through here so the tiles render identically regardless of
/// source: Claude / Codex / Grok feed token/cost from their CLI logs (estimated dollars),
/// Cursor feeds server-priced dollars from its CSV export (`estimated: false`). The data shape
/// (`DailyUsageSeries`) is a provider-neutral per-day carrier shared by every source.
enum SpendTileMapper {
    /// Append the three spend tiles (Today / Yesterday / Last 30 Days). Callers only invoke this once the
    /// source was actually read, so a period with no usage is a real, measured zero — it renders
    /// "$0.00 · 0 tokens", not "No data". "No data" is reserved for a source we couldn't read at all
    /// (missing log, failed API/CSV), where the caller appends nothing and the tile falls back on its own.
    /// `estimated` flags the dollar value as a local estimate (drives the ⓘ); pass `false` for
    /// server-priced sources like Cursor.
    static func appendTokenUsage(
        _ usage: DailyUsageSeries,
        to lines: inout [MetricLine],
        now: Date = Date(),
        estimated: Bool = true
    ) {
        let today = dayKey(from: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now).map(dayKey(from:))

        let todayEntry = usage.daily.first { dayKey(fromUsageDate: $0.date) == today }
        let yesterdayEntry = usage.daily.first { dayKey(fromUsageDate: $0.date) == yesterday }

        lines.append(dayUsageLine(label: "Today", entry: todayEntry, estimated: estimated))
        lines.append(dayUsageLine(label: "Yesterday", entry: yesterdayEntry, estimated: estimated))

        let totalTokens = usage.daily.reduce(0) { $0 + $1.totalTokens }
        let costSamples = usage.daily.compactMap(\.costUSD)
        let totalCost = costSamples.isEmpty ? nil : costSamples.reduce(0, +)
        lines.append(.values(label: "Last 30 Days", values: spendValues(tokens: totalTokens, costUSD: totalCost, estimated: estimated)))
    }

    /// Number of days before `now` the trend window spans; with `now` itself that's 31 calendar bars,
    /// matching the ccusage `daysBack: 30` query window the daily rows come from.
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

    /// Query `ccusage` for the last 30 days and, on success, append the spend tiles + usage-trend chart.
    /// Claude and Codex both source their spend from `ccusage` and handle the result identically, so the
    /// query → append sequence (and its "estimated from local logs" note) lives here once.
    static func appendCcusageUsage(
        using runner: CcusageRunner,
        provider: CcusageProvider,
        homePath: String?,
        to lines: inout [MetricLine],
        now: Date
    ) async {
        let since = CcusageRunner.sinceString(daysBack: 30, from: now)
        guard case .success(let usage) = await runner.query(provider: provider, since: since, homePath: homePath) else {
            return
        }
        appendTokenUsage(usage, to: &lines, now: now)
        appendUsageTrend(usage, to: &lines, now: now, note: "Estimated from local logs at API rates")
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
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func dayKey(fromUsageDate rawDate: String) -> String? {
        let value = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

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

        if let date = OpenUsageISO8601.date(from: value) {
            return dayKey(from: date)
        }
        return nil
    }

    private static func dayUsageLine(label: String, entry: DailyUsageEntry?, estimated: Bool) -> MetricLine {
        .values(label: label, values: spendValues(tokens: entry?.totalTokens ?? 0, costUSD: entry?.costUSD, estimated: estimated))
    }

    /// One period's spend as raw values: the estimated dollars followed by the measured token count,
    /// rendered combined as "$4.08 · 1.2M tokens". The token value carries the "tokens" unit (the same
    /// way Codex credits carry "credits"), so the three spend tiles read consistently.
    ///
    /// A zero is a real, measured value here, not absence — a day with no usage genuinely cost nothing,
    /// so it reads "$0.00 · 0 tokens" rather than "No data" (which is reserved for a source we couldn't
    /// read at all, where no line is appended). The dollar is shown even at $0.00; the *only* time it's
    /// omitted is an unpriced day that still used tokens (e.g. an unknown model), whose cost is genuinely
    /// unknown — not zero — so that row shows just the token count. `estimated` flags the dollars as a
    /// local estimate (the ⓘ); token counts are always measured, never flagged.
    private static func spendValues(tokens: Int, costUSD: Double?, estimated: Bool) -> [MetricValue] {
        var values: [MetricValue] = []
        if let costUSD {
            values.append(MetricValue(number: costUSD, kind: .dollars, estimated: estimated))
        } else if tokens == 0 {
            values.append(MetricValue(number: 0, kind: .dollars, estimated: estimated))
        }
        values.append(MetricValue(number: Double(tokens), kind: .count, label: "tokens"))
        return values
    }
}

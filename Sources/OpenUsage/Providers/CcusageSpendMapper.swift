import Foundation

/// Turns ccusage's local daily token/cost data into Today / Yesterday / Last 30 Days `MetricLine`s.
/// Shared by the Claude and Codex providers (both read the same `ccusage` CLI), so this lives outside
/// any one provider's mapper rather than being borrowed across provider folders.
enum CcusageSpendMapper {
    static func appendTokenUsage(_ usage: CcusageDailyUsage, to lines: inout [MetricLine], now: Date = Date()) {
        let today = dayKey(from: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now).map(dayKey(from:))

        let todayEntry = usage.daily.first { dayKey(fromUsageDate: $0.date) == today }
        let yesterdayEntry = usage.daily.first { dayKey(fromUsageDate: $0.date) == yesterday }

        lines.append(dayUsageLine(label: "Today", entry: todayEntry))
        lines.append(dayUsageLine(label: "Yesterday", entry: yesterdayEntry))

        let totalTokens = usage.daily.reduce(0) { $0 + $1.totalTokens }
        let costValues = usage.daily.compactMap(\.costUSD)
        let totalCost = costValues.isEmpty ? nil : costValues.reduce(0, +)
        if totalTokens > 0 {
            lines.append(.text(
                label: "Last 30 Days",
                value: costAndTokensLabel(tokens: totalTokens, costUSD: totalCost)
            ))
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

    private static func dayUsageLine(label: String, entry: CcusageDay?) -> MetricLine {
        .text(label: label, value: costAndTokensLabel(tokens: entry?.totalTokens ?? 0, costUSD: entry?.costUSD))
    }

    private static func costAndTokensLabel(tokens: Int, costUSD: Double?) -> String {
        var parts: [String] = []
        if let costUSD {
            parts.append(Formatters.currency(costUSD))
        }
        parts.append("\(formatTokens(tokens)) tokens")
        return parts.joined(separator: " · ")
    }

    private static func formatTokens(_ tokens: Int) -> String {
        let absValue = abs(tokens)
        let sign = tokens < 0 ? "-" : ""
        let units: [(threshold: Double, divisor: Double, suffix: String)] = [
            (1_000_000_000, 1_000_000_000, "B"),
            (1_000_000, 1_000_000, "M"),
            (1_000, 1_000, "K")
        ]
        for unit in units where Double(absValue) >= unit.threshold {
            let scaled = Double(absValue) / unit.divisor
            let formatted = scaled >= 10
                ? String(Int(scaled.rounded()))
                : String(format: "%.1f", scaled).replacingOccurrences(of: ".0", with: "")
            return sign + formatted + unit.suffix
        }
        return "\(tokens)"
    }
}

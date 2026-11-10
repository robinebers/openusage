import Foundation

/// Amp's `userDisplayBalanceInfo` answers with the text `amp usage` prints, one line per allowance:
///
///     Signed in as amp@example.com (example)
///     Amp Megawatt Tier: agent usage $19.98 of $20.00 remaining (100%), orb usage 737.6h of 750h a1.small
///       orb hours remaining (98%) - period 2026-11-09 to 2026-12-09, ends in 29 days
///     Amp Free: 61% remaining today (resets daily)
///     Individual credits: $57.45 remaining (set up auto-reload to avoid running out) - https://ampcode.com/settings
///
/// Each row shows only what its line states. The tier's period dates its resets; Amp Free's daily reset has
/// no time in the text, so it has none here. Workspace balances are left out.
enum AmpUsageMapper {
    static func map(_ body: Data) throws -> ProviderUsage {
        guard let text = displayText(body) else { throw ProviderError.invalidResponse }
        var plan: String?
        var lines: [MetricLine] = []

        if let tier = text.firstMatch(of: #/Amp (?<plan>[^\n]+?) Tier: agent usage \$(?<left>[0-9.,]+) of \$(?<limit>[0-9.,]+) remaining(?<rest>[^\n]*)/#),
           let left = number(tier.left), let limit = number(tier.limit), limit > 0 {
            plan = String(tier.plan)
            let period = billingPeriod(in: tier.rest)
            let periodMs = period.map { Int($0.end.timeIntervalSince($0.start) * 1000) }
            lines.append(.progress(label: "Agent Usage", used: ((limit - left) * 100).rounded() / 100, limit: limit,
                                   format: .dollars, resetsAt: period?.end, periodDurationMs: periodMs))
            if let orb = tier.rest.firstMatch(of: #/orb usage (?<left>[0-9.,]+)h of (?<limit>[0-9.,]+)h/#),
               let orbLeft = number(orb.left), let orbLimit = number(orb.limit), orbLimit > 0 {
                lines.append(.progress(label: "Orb Hours", used: ((orbLimit - orbLeft) * 10).rounded() / 10, limit: orbLimit,
                                       format: .count(suffix: "hours"), resetsAt: period?.end, periodDurationMs: periodMs))
            }
        }

        if let free = text.firstMatch(of: #/Amp Free: \$(?<left>[0-9.,]+)\s*/\s*\$(?<limit>[0-9.,]+) remaining/#),
           let left = number(free.left), let limit = number(free.limit), limit > 0 {
            lines.append(.percent("Amp Free", (limit - left) / limit * 100, periodMs: MetricPeriod.dayMs))
        } else if let free = text.firstMatch(of: #/Amp Free: (?<left>[0-9.]+)% remaining/#), let left = number(free.left) {
            lines.append(.percent("Amp Free", 100 - left, periodMs: MetricPeriod.dayMs))
        }
        if plan == nil, lines.contains(where: { $0.label == "Amp Free" }) { plan = "Free" }

        if let credits = text.firstMatch(of: #/Individual credits: \$(?<left>[0-9.,]+) remaining/#), let left = number(credits.left) {
            lines.append(.values(label: "Individual Credits", values: [MetricValue(number: left, kind: .dollars)]))
        }

        guard !lines.isEmpty else { throw ProviderError.invalidResponse }
        return ProviderUsage(plan: plan, lines: lines)
    }

    /// The address after "Signed in as", which names the account.
    static func email(_ body: Data) -> String? {
        displayText(body)?.firstMatch(of: #/Signed in as (?<email>[^\s(]+)/#).map { String($0.email) }
    }

    private static func displayText(_ body: Data) -> String? {
        guard let result = ProviderParse.jsonObject(body)?["result"] as? [String: Any],
              let text = result["displayText"] as? String else { return nil }
        return text.replacingOccurrences(of: "**", with: "")
    }

    private static func number(_ text: Substring) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    /// The tier's billing dates are whole days, read as UTC midnights.
    private static func billingPeriod(in text: Substring) -> (start: Date, end: Date)? {
        guard let match = text.firstMatch(of: #/period (?<start>\d{4}-\d{2}-\d{2}) to (?<end>\d{4}-\d{2}-\d{2})/#) else { return nil }
        let day = Date.ISO8601FormatStyle().year().month().day()
        guard let start = try? day.parse(String(match.start)), let end = try? day.parse(String(match.end)), end > start else {
            return nil
        }
        return (start, end)
    }
}

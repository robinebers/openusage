import Foundation

enum MuseUsageMapper {
    /// Muse leaves out `subs_usage` while the 5-hour window is idle, even when the week has usage, so the
    /// card keeps its last known values then. A kept window whose reset has passed reads 0%.
    static func map(_ account: MuseAccount, lastKnown: [MetricLine], now: Date) throws -> ProviderUsage {
        guard account.isSubscribed else {
            throw ProviderError.unavailable("No Muse Code subscription on this account.")
        }
        guard let usage = account.usage else {
            return ProviderUsage(plan: account.plan, lines: lastKnown.map { aged($0, now: now) })
        }
        let lines = [
            usage.window.map { MetricLine.percent("Session", $0.usedPercent, resetsAt: $0.resetsAt, periodMs: MetricPeriod.sessionMs) },
            usage.weekly.map { MetricLine.percent("Weekly", $0.usedPercent, resetsAt: $0.resetsAt, periodMs: MetricPeriod.weekMs) }
        ]
        return ProviderUsage(plan: account.plan, lines: lines.compactMap { $0 })
    }

    private static func aged(_ line: MetricLine, now: Date) -> MetricLine {
        guard case .progress(let label, _, _, _, let resetsAt?, let periodMs) = line, resetsAt <= now else { return line }
        return .percent(label, 0, periodMs: periodMs)
    }
}

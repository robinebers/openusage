import Foundation

enum MuseUsageMapper {
    /// Muse leaves `subs_usage` out while the 5-hour window is idle, even when the week has usage, so a
    /// window it leaves out keeps its last known value. A kept window whose reset has passed reads 0%.
    static func map(_ account: MuseAccount, lastKnown: [MetricLine], now: Date) throws -> ProviderUsage {
        guard account.isSubscribed else {
            throw ProviderError.unavailable("No Muse Code subscription on this account.")
        }
        let lines = [
            line("Session", account.usage?.window, periodMs: MetricPeriod.sessionMs, lastKnown: lastKnown, now: now),
            line("Weekly", account.usage?.weekly, periodMs: MetricPeriod.weekMs, lastKnown: lastKnown, now: now)
        ]
        return ProviderUsage(plan: account.plan, lines: lines.compactMap { $0 })
    }

    private static func line(
        _ label: String, _ window: MuseAccount.Window?, periodMs: Int, lastKnown: [MetricLine], now: Date
    ) -> MetricLine? {
        if let window {
            return .percent(label, window.usedPercent, resetsAt: window.resetsAt, periodMs: periodMs)
        }
        guard let kept = lastKnown.first(where: { $0.label == label }) else { return nil }
        guard case .progress(_, _, _, _, let resetsAt?, _) = kept, resetsAt <= now else { return kept }
        return .percent(label, 0, periodMs: periodMs)
    }
}

import Foundation

enum MuseUsageMapper {
    /// Muse leaves out `subs_usage` until the plan's first use and while the 5-hour window is idle, even when
    /// the week has usage, so the card keeps its last known values then. A kept window whose reset has passed,
    /// and a window Muse has never reported, read 0%.
    static func map(_ account: MuseAccount, lastKnown: [MetricLine], now: Date) throws -> ProviderUsage {
        guard account.isSubscribed else {
            throw ProviderError.unavailable("No Muse Code subscription on this account.")
        }
        let windows = [
            ("Session", account.usage?.window, MetricPeriod.sessionMs),
            ("Weekly", account.usage?.weekly, MetricPeriod.weekMs)
        ]
        let lines = windows.map { label, window, periodMs in
            if let window {
                return MetricLine.percent(label, window.usedPercent, resetsAt: window.resetsAt, periodMs: periodMs)
            }
            if account.usage == nil, let kept = lastKnown.first(where: { $0.label == label }) {
                return aged(kept, now: now)
            }
            return MetricLine.percent(label, 0, periodMs: periodMs)
        }
        return ProviderUsage(plan: account.plan, lines: lines)
    }

    private static func aged(_ line: MetricLine, now: Date) -> MetricLine {
        guard case .progress(let label, _, _, _, let resetsAt?, let periodMs) = line, resetsAt <= now else { return line }
        return .percent(label, 0, periodMs: periodMs)
    }
}

import Foundation

/// Shared display formatters for live usage data: the mode-aware deadline/reset phrasing
/// (`deadlineLabel`, `resetRelativeLabel`, `resetAbsoluteLabel`), compact durations, and USD currency.
enum Formatters {
    static func currency(_ amount: Double, fractionDigits: Int = 2) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = fractionDigits
        f.minimumFractionDigits = fractionDigits
        // The fallback must also respect the requested precision: a raw "$\(amount)" would leak the
        // double's full decimals (e.g. "$180.168"), which is exactly the rounding glitch we're fixing.
        return f.string(from: amount as NSNumber) ?? "$\(String(format: "%.\(fractionDigits)f", amount))"
    }

    /// The one mode-aware deadline phrase, shared by every "<verb> + when" label (reset countdowns,
    /// run-out projections): `.relative` → "<prefix> in 2d 6h", `.absolute` → "<prefix> today at
    /// 5:30 PM" / "<prefix> tomorrow at 9:00 AM" / "<prefix> Feb 15 at 3:45 PM" (ported from the
    /// original's `formatResetAbsoluteLabel`; time uses the locale's 12/24-hour convention). An
    /// imminent deadline (≤5 min out relative, past-due absolute) collapses to "<prefix> soon".
    static func deadlineLabel(
        _ prefix: String,
        at date: Date,
        mode: ResetDisplayMode,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let when = whenLabel(at: date, mode: mode, now: now, calendar: calendar) else { return nil }
        if when == imminent { return "\(prefix) \(when)" }
        switch mode {
        case .relative: return "\(prefix) in \(when)"
        case .absolute: return "\(prefix) \(when)"
        }
    }

    /// The verb-less "when" phrase shared by `deadlineLabel` (which prefixes a verb) and the
    /// reset-credit tooltip (which lists bare entries): `.relative` → "2d 6h" / `imminent`;
    /// `.absolute` → "today at 5:30 PM" / "tomorrow at 9:00 AM" / "Feb 15 at 3:45 PM" / `imminent`
    /// (past-due or ≤5 min out). `nil` only when the duration is non-finite.
    static func whenLabel(
        at date: Date,
        mode: ResetDisplayMode,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        switch mode {
        case .relative:
            let seconds = date.timeIntervalSince(now)
            if seconds <= 5 * 60 { return imminent }
            return compactDuration(seconds)
        case .absolute:
            guard date.timeIntervalSince(now) > 0 else { return imminent }
            let dayDiff = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: now),
                to: calendar.startOfDay(for: date)
            ).day ?? 0
            // The wall-clock part honors the user's Auto/12h/24h time-format setting.
            let time = TimeFormatSetting.current.shortTime(date)
            if dayDiff <= 0 { return "today at \(time)" }
            if dayDiff == 1 { return "tomorrow at \(time)" }
            let day = date.formatted(.dateTime.month(.abbreviated).day())
            return "\(day) at \(time)"
        }
    }

    /// The collapsed phrase for a deadline that's past-due or within ~5 minutes — too close to print a
    /// useful countdown. Shared so `deadlineLabel` and any bare-`whenLabel` caller agree on the wording.
    static let imminent = "soon"

    static func resetRelativeLabel(until resetsAt: Date, now: Date = Date()) -> String? {
        deadlineLabel("Resets", at: resetsAt, mode: .relative, now: now)
    }

    static func resetAbsoluteLabel(at resetsAt: Date, now: Date = Date(), calendar: Calendar = .current) -> String? {
        deadlineLabel("Resets", at: resetsAt, mode: .absolute, now: now, calendar: calendar)
    }

    static func compactDuration(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let totalMinutes = max(1, Int((seconds / 60).rounded(.up)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}

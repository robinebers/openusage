import Foundation

/// Shared display formatters for live usage data: the mode-aware `whenLabel`, the compact clock
/// readings, and compact durations.
enum Formatters {
    /// The app's compact month/day, e.g. "Jun 21" — localized, no year. Shared so every short calendar
    /// date (reset deadlines, the Usage Trend axis) reads the same and changes in one place.
    static func monthDayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The verb-less "when" phrase of the claim timeline and the claim notice: `.relative` → "2d 6h" /
    /// `imminent`; `.absolute` → "today at 5:30 PM" / "tomorrow at 9:00 AM" / "Feb 15 at 3:45 PM" /
    /// `imminent` (past-due or ≤5 min out). `nil` only when the duration is non-finite.
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
            return "\(monthDayLabel(date)) at \(time)"
        }
    }

    /// The collapsed phrase for a deadline that's past-due or within ~5 minutes — too close to print a
    /// useful countdown. Shared so every caller agrees on the wording.
    static let imminent = "soon"

    /// The shortest clock reading for a reset column: "5:30 PM" today, "Tue 5 PM" within the week,
    /// "Oct 29" further out.
    static func compactClock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days <= 0 { return TimeFormatSetting.current.shortTime(date) }
        if days < 7 { return TimeFormatSetting.current.weekdayHour(date) }
        return monthDayLabel(date)
    }

    /// Compact "Xd Yh" / "Xh Ym" / "Xm" duration. At the day scale it always shows two units — the
    /// hours ride along even when zero ("4d 0h") — so a span 4 days + 52 min out never reads as a flat
    /// "4d" that hides the sub-day remainder. Minutes are dropped at the day scale.
    static func compactDuration(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let totalMinutes = max(1, Int((seconds / 60).rounded(.up)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}

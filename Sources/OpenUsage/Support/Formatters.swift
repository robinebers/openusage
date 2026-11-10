import Foundation

enum Formatters {
    static func monthDayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

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
            return countdown(to: date, now: now, calendar: calendar)
        case .absolute:
            guard date.timeIntervalSince(now) > 0 else { return imminent }
            let dayDiff = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: now),
                to: calendar.startOfDay(for: date)
            ).day ?? 0
            let time = TimeFormatSetting.current.shortTime(date)
            if dayDiff <= 0 { return "today at \(time)" }
            if dayDiff == 1 { return "tomorrow at \(time)" }
            return "\(monthDayLabel(date)) at \(time)"
        }
    }

    static let imminent = "soon"

    static func compactClock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days <= 0 { return TimeFormatSetting.current.shortTime(date) }
        if days < 7 { return TimeFormatSetting.current.weekdayTime(date) }
        return monthDayLabel(date)
    }

    /// The time left until `date`: calendar months and days once it is a month or more away, like
    /// "3m 12d", and `compactDuration` below that.
    static func countdown(to date: Date, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let left = calendar.dateComponents([.month, .day], from: now, to: date)
        if let months = left.month, months >= 1 { return "\(months)m \(left.day ?? 0)d" }
        return compactDuration(date.timeIntervalSince(now))
    }

    static func compactDuration(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let totalMinutes = max(1, ProviderParse.int((seconds / 60).rounded(.up)) ?? .max)
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

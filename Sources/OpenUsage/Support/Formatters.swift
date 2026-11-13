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
            return duration(from: now, to: date, calendar: calendar)
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
            return dateAndTime(date)
        }
    }

    static func dateAndTime(_ date: Date) -> String {
        "\(monthDayLabel(date)) at \(TimeFormatSetting.current.shortTime(date))"
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

    /// The time from `start` to `end`, rounded up to the minute, in its largest unit and the next one down,
    /// like "4h 12m", "3mo 17d", or "1y 2mo". Years and months are calendar ones; a zero second unit is left out.
    static func duration(from start: Date, to end: Date, calendar: Calendar = .current) -> String? {
        let seconds = end.timeIntervalSince(start)
        guard seconds.isFinite, seconds > 0 else { return nil }
        let end = start.addingTimeInterval((seconds / 60).rounded(.up) * 60)
        let months = calendar.dateComponents([.year, .month], from: start, to: end)
        let monthsEnd = calendar.date(byAdding: months, to: start) ?? start
        let minutes = ProviderParse.int((end.timeIntervalSince(monthsEnd) / 60).rounded()) ?? .max
        let parts = [
            (months.year ?? 0, "y"), (months.month ?? 0, "mo"),
            (minutes / (24 * 60), "d"), (minutes % (24 * 60) / 60, "h"), (minutes % 60, "m")
        ]
        guard let first = parts.firstIndex(where: { $0.0 > 0 }) else { return nil }
        let shown = parts[first...].prefix(2).filter { $0.0 > 0 }
        return shown.map { "\($0.0)\($0.1)" }.joined(separator: " ")
    }
}

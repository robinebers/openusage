import Foundation

/// How wall-clock times read (the absolute reset labels): the system's 12/24-hour convention, or
/// an explicit override.
enum TimeFormatSetting: String, Hashable, Sendable, CaseIterable {
    case auto
    case twelveHour = "12h"
    case twentyFourHour = "24h"

    static let key = "timeFormat"

    /// The user's choice, read live; `.auto` when unset.
    static var current: TimeFormatSetting { UserDefaults.standard.enumValue(forKey: key, default: .auto) }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .twelveHour: return "12-hour"
        case .twentyFourHour: return "24-hour"
        }
    }

    /// Short time string ("5:30 PM" / "17:30") honoring the override, via the locale's hour cycle.
    func shortTime(_ date: Date, base: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale(base)))
    }

    /// Weekday and hour ("Tue 5 PM" / "Tue 17") honoring the override.
    func weekdayHour(_ date: Date, base: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale(base)).weekday(.abbreviated).hour())
    }

    private func locale(_ base: Locale) -> Locale {
        var components = Locale.Components(locale: base)
        switch self {
        case .auto:
            break
        case .twelveHour:
            components.hourCycle = .oneToTwelve
        case .twentyFourHour:
            components.hourCycle = .zeroToTwentyThree
        }
        return Locale(components: components)
    }
}

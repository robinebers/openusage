import Foundation

/// How wall-clock times read (the absolute reset labels): the system's 12/24-hour convention, or
/// an explicit override — matching the original app's Auto/12h/24h setting.
enum TimeFormatSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case auto
    case twelveHour = "12h"
    case twentyFourHour = "24h"

    static let key = "timeFormat"
    static var fallback: TimeFormatSetting { .auto }

    // `current` (the user's current choice, read live) comes from `UserDefaultsBacked`.

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .twelveHour: return "12-hour"
        case .twentyFourHour: return "24-hour"
        }
    }

    /// Short time string ("5:30 PM" / "17:30") honoring the override, via the locale's hour cycle.
    func shortTime(_ date: Date, base: Locale = .current) -> String {
        var components = Locale.Components(locale: base)
        switch self {
        case .auto:
            break
        case .twelveHour:
            components.hourCycle = .oneToTwelve
        case .twentyFourHour:
            components.hourCycle = .zeroToTwentyThree
        }
        return date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(components: components))
        )
    }
}

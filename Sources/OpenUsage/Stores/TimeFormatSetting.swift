import Foundation

enum TimeFormatSetting: String, Hashable, Sendable, CaseIterable {
    case auto
    case twelveHour = "12h"
    case twentyFourHour = "24h"

    static let key = "timeFormat"

    static var current: TimeFormatSetting { UserDefaults.standard.enumValue(forKey: key, default: .auto) }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .twelveHour: return "12-hour"
        case .twentyFourHour: return "24-hour"
        }
    }

    func shortTime(_ date: Date, base: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale(base)))
    }

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

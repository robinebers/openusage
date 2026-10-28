import Foundation

extension RateLimitResetsDetail {
    enum Content: Equatable {
        case timeline([Entry])
        case unknownExpiries(count: Int)
        case empty

        var entries: [Entry] {
            if case .timeline(let entries) = self { entries } else { [] }
        }
    }

    nonisolated static func content(count: Int, expiries: [Date], now: Date = Date()) -> Content {
        let entries = entries(from: expiries, now: now)
        if !entries.isEmpty { return .timeline(entries) }
        if count > 0 { return .unknownExpiries(count: count) }
        return .empty
    }

    /// The expiries still on the timeline once `claimed` resets have been used: one occurrence of a
    /// date per claim, since a login that repeats one expiry per reset left shares it between nodes.
    nonisolated static func visibleExpiries(_ expiries: [Date], claimed: [Date: Int]) -> [Date] {
        var remaining = claimed
        return expiries.filter { date in
            guard let left = remaining[date], left > 0 else { return true }
            remaining[date] = left - 1
            return false
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let number: Int
        let date: Date
        let key: Key
        let severity: WidgetData.MeterSeverity
        let time: String
        let countdown: String?

        struct Key: Hashable {
            let date: Date
            let ordinal: Int
        }

        var accessibilityLabel: String {
            "Reset \(number), \(time)" + (countdown.map { ", expires in \($0)" } ?? "")
        }
    }

    nonisolated static func entries(from expiries: [Date], now: Date = Date()) -> [Entry] {
        var seen: [Date: Int] = [:]
        return expiries.sorted().enumerated().map { index, date in
            let ordinal = seen[date, default: 0]
            seen[date] = ordinal + 1
            let relative = Formatters.whenLabel(at: date, mode: .relative, now: now)
            let absolute = Formatters.whenLabel(at: date, mode: .absolute, now: now)
            let imminent = (relative == nil || relative == Formatters.imminent)
            return Entry(
                id: index,
                number: index + 1,
                date: date,
                key: Entry.Key(date: date, ordinal: ordinal),
                severity: WidgetData.expirySeverity(secondsRemaining: date.timeIntervalSince(now)),
                time: (imminent || absolute == nil) ? "Expiring soon" : absolute!,
                countdown: imminent ? nil : relative
            )
        }
    }
}

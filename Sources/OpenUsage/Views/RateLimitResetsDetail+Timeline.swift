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
            /// The exact record a window entry claims; nil on the flat timeline, which claims by date.
            var reset: ZAIReset?
        }

        var accessibilityLabel: String {
            "Reset \(number), \(time)" + (countdown.map { ", expires in \($0)" } ?? "")
        }
    }

    struct Window: Equatable {
        let window: ZAIResetWindow
        let entries: [Entry]
    }

    /// Each window's resets on its own timeline, in the given earliest-first order.
    nonisolated static func windows(_ resets: [ZAIReset], now: Date = Date()) -> [Window] {
        ZAIResetWindow.allCases.compactMap { window in
            let resets = resets.filter { $0.window == window }
            guard !resets.isEmpty else { return nil }
            return Window(window: window, entries: entries(from: resets.map { ($0.expiresAt, $0) }, now: now))
        }
    }

    nonisolated static func entries(from expiries: [Date], now: Date = Date()) -> [Entry] {
        entries(from: expiries.map { ($0, nil) }, now: now)
    }

    /// Each expiry travels with the record it claims, so sorting can never pair a date with another record.
    nonisolated static func entries(from items: [(date: Date, reset: ZAIReset?)], now: Date = Date()) -> [Entry] {
        var seen: [Date: Int] = [:]
        let sorted = items.sorted { ($0.date, $0.reset?.recordID ?? 0) < ($1.date, $1.reset?.recordID ?? 0) }
        return sorted.enumerated().map { index, item in
            let (date, reset) = item
            let ordinal = seen[date, default: 0]
            seen[date] = ordinal + 1
            let relative = Formatters.whenLabel(at: date, mode: .relative, now: now)
            let absolute = Formatters.whenLabel(at: date, mode: .absolute, now: now)
            let imminent = (relative == nil || relative == Formatters.imminent)
            return Entry(
                id: index,
                number: index + 1,
                date: date,
                key: Entry.Key(date: date, ordinal: ordinal, reset: reset),
                severity: WidgetData.expirySeverity(secondsRemaining: date.timeIntervalSince(now)),
                time: (imminent || absolute == nil) ? "Expiring soon" : absolute!,
                countdown: imminent ? nil : relative
            )
        }
    }
}

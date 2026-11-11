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

    /// The popover's rows: one per reset, earliest first, each titled by its kind. Before a provider's list
    /// is read the row's expiries still show, untitled, until the read names them.
    nonisolated static func content(
        count: Int, expiries: [Date], items: [ResetItem], claimed: [ResetClaimRef: Int] = [:], now: Date = Date()
    ) -> Content {
        let spent = claimed.values.reduce(0, +)
        let entries = items.isEmpty
            ? entries(from: expiries.map { ($0, nil) }, now: now)
            : entries(from: visibleItems(items, claimed: claimed).map { ($0.expiresAt, $0) }, now: now)
        if !entries.isEmpty { return .timeline(entries) }
        if count - spent > 0 { return .unknownExpiries(count: count - spent) }
        return .empty
    }

    /// The resets still listed once `claimed` ones have been used here: one row of a record per claim,
    /// since a grant with several resets left lists one row for each.
    nonisolated static func visibleItems(_ items: [ResetItem], claimed: [ResetClaimRef: Int]) -> [ResetItem] {
        var remaining = claimed
        return items.filter { item in
            guard let left = remaining[item.claim], left > 0 else { return true }
            remaining[item.claim] = left - 1
            return false
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let number: Int
        let date: Date
        let key: Key
        let severity: WidgetData.MeterSeverity
        /// The date and time it expires.
        let expiry: String
        /// The time left, or "Expiring" for a reset about to lapse.
        let countdown: String?
        /// The reset this row spends; nil while the provider's list hasn't been read.
        let item: ResetItem?

        nonisolated static let expiring = "Expiring"

        /// A row is its record plus its place among that record's rows, so two resets sharing an expiry
        /// stay apart and a confirmation never carries over to another record.
        struct Key: Hashable {
            let claim: ResetClaimRef?
            let date: Date
            let ordinal: Int
        }

        var accessibilityLabel: String {
            ["Reset \(number)", item?.kind.title, expiry, countdown.map { $0 == Self.expiring ? "expiring" : "expires in \($0)" }]
                .compactMap { $0 }.joined(separator: ", ")
        }
    }

    /// Each expiry travels with the reset it claims, so sorting can never pair a date with another record.
    nonisolated static func entries(from rows: [(date: Date, item: ResetItem?)], now: Date = Date()) -> [Entry] {
        var seen: [Entry.Key: Int] = [:]
        let sorted = rows.sorted { lhs, rhs in
            guard let left = lhs.item, let right = rhs.item else { return lhs.date < rhs.date }
            return ResetItem.timelineOrder(left, right)
        }
        return sorted.enumerated().map { index, row in
            let base = Entry.Key(claim: row.item?.claim, date: row.date, ordinal: 0)
            let ordinal = seen[base, default: 0]
            seen[base] = ordinal + 1
            let relative = Formatters.whenLabel(at: row.date, mode: .relative, now: now)
            return Entry(
                id: index,
                number: index + 1,
                date: row.date,
                key: Entry.Key(claim: row.item?.claim, date: row.date, ordinal: ordinal),
                severity: WidgetData.expirySeverity(secondsRemaining: row.date.timeIntervalSince(now)),
                expiry: "\(Formatters.monthDayLabel(row.date)) at \(TimeFormatSetting.current.shortTime(row.date))",
                countdown: relative == Formatters.imminent ? Entry.expiring : relative,
                item: row.item
            )
        }
    }
}

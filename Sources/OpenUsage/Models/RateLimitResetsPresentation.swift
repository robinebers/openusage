import Foundation

/// Pure presentation data for the rate-limit-resets popover. Keeping this outside the SwiftUI view
/// makes the count/expiry state machine and timeline formatting independently testable and nonisolated.
enum RateLimitResetsPresentation {
    /// What the popover body renders after resolving the available count and expiry list.
    enum Content: Equatable {
        case timeline([Entry])
        case unknownExpiries(count: Int)
        case empty
    }

    /// One timeline node's display strings, derived from a credit's expiry instant.
    struct Entry: Identifiable, Equatable {
        let id: Int          // 0-based row index (soonest first)
        let number: Int      // 1-based reset number, shown inside the dot
        let severity: WidgetData.MeterSeverity
        let time: String       // exact expiry, e.g. "Jul 12 at 5:30 PM"; "Expiring soon" when imminent
        let countdown: String? // "12d 18h"; nil when imminent (no useful countdown to show)

        var accessibilityLabel: String {
            "Reset \(number), \(time)" + (countdown.map { ", expires in \($0)" } ?? "")
        }
    }

    /// Empty `expiries` is ambiguous: a genuinely empty balance (`count == 0`) shows the empty state,
    /// but a positive `count` with no expiries means the dedicated expiry fetch was unavailable and the
    /// row fell back to the usage-body count — show that count rather than "no resets".
    static func content(count: Int, expiries: [Date], now: Date = Date()) -> Content {
        let entries = entries(from: expiries, now: now)
        if !entries.isEmpty { return .timeline(entries) }
        if count > 0 { return .unknownExpiries(count: count) }
        return .empty
    }

    /// Build the timeline entries from raw expiry instants: sort soonest-first, number from 1, and pair
    /// each exact expiry time with its countdown. A past-due or ≤5-minute expiry can't print a useful
    /// exact time or countdown, so it reads "Expiring soon" with no trailing countdown. Imminence keys
    /// off the *relative* window — `Formatters.whenLabel(.relative)` collapses to `soon` at ≤5 minutes,
    /// while `.absolute` only collapses once past-due — so both formats agree instead of the exact time
    /// printing a wall-clock while the countdown reads "soon".
    static func entries(from expiries: [Date], now: Date = Date()) -> [Entry] {
        expiries.sorted().enumerated().map { index, date in
            let relative = Formatters.whenLabel(at: date, mode: .relative, now: now)
            let absolute = Formatters.whenLabel(at: date, mode: .absolute, now: now)
            let imminent = (relative == nil || relative == Formatters.imminent)
            return Entry(
                id: index,
                number: index + 1,
                severity: WidgetData.expirySeverity(secondsRemaining: date.timeIntervalSince(now)),
                time: (imminent || absolute == nil) ? "Expiring soon" : absolute!,
                countdown: imminent ? nil : relative
            )
        }
    }
}

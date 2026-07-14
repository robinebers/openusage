import Foundation

/// The three OpenCode Go plan windows, as observed-local spend against the published caps
/// ($12 / rolling 5h, $30 / week, $60 / month). Built by `OpenCodeGoWindowMath` from the local
/// `opencode-go` messages; only the meters read these (the spend tiles use all-provider OpenCode usage).
struct OpenCodeGoWindows: Sendable, Equatable {
    var sessionSpend: Double
    var sessionResetsAt: Date?
    var weeklySpend: Double
    var weeklyResetsAt: Date?
    var monthlySpend: Double
    var monthlyResetsAt: Date?
    var monthlyPeriodMs: Int?
}

/// Window math ported faithfully from the legacy `opencode-go` plugin (and matching CodexBar): a rolling
/// 5-hour session, a UTC-ISO week (Monday start), and a month anchored to the day-of-month of the
/// earliest-ever local Go usage (calendar-month fallback when there is none). Pure and UTC-based so it is
/// deterministic and unit-testable; `now`/anchor come from the caller.
enum OpenCodeGoWindowMath {
    static let fiveHoursMs = Double(MetricPeriod.sessionMs)
    static let weekMs = Double(MetricPeriod.weekMs)

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// - Parameters:
    ///   - costs: `(timestampMs, cost)` for every local `opencode-go` assistant message in range; only
    ///     rows inside a window contribute to that window.
    ///   - anchorMs: earliest-ever `opencode-go` usage (ms) for the monthly cycle anchor; `nil` → UTC
    ///     calendar month.
    static func compute(costs: [(ms: Double, cost: Double)], anchorMs: Double?, now: Date) -> OpenCodeGoWindows {
        let nowMs = ms(now)
        let bounds = windowBounds(nowMs: nowMs, anchorMs: anchorMs)

        let sessionSpend = sumRange(costs, start: bounds.sessionStart, end: nowMs)
        let oldestInSession = costs.lazy.filter { $0.ms >= bounds.sessionStart && $0.ms < nowMs }.map(\.ms).min()
        let sessionResetsAt = date(ms: (oldestInSession ?? nowMs) + fiveHoursMs)

        let weeklySpend = sumRange(costs, start: bounds.weekStart, end: bounds.weekEnd)
        let monthlySpend = sumRange(costs, start: bounds.monthStart, end: bounds.monthEnd)

        return OpenCodeGoWindows(
            sessionSpend: sessionSpend,
            sessionResetsAt: sessionResetsAt,
            weeklySpend: weeklySpend,
            weeklyResetsAt: date(ms: bounds.weekEnd),
            monthlySpend: monthlySpend,
            monthlyResetsAt: date(ms: bounds.monthEnd),
            monthlyPeriodMs: Int((bounds.monthEnd - bounds.monthStart).rounded())
        )
    }

    /// Whether a row contributes to at least one cap currently shown to the user. Malformed Go costs
    /// outside these ranges must not hide otherwise valid live meters.
    static func containsActiveWindow(timestampMs: Double, anchorMs: Double?, now: Date) -> Bool {
        let nowMs = ms(now)
        let bounds = windowBounds(nowMs: nowMs, anchorMs: anchorMs)
        return (timestampMs >= bounds.sessionStart && timestampMs < nowMs)
            || (timestampMs >= bounds.weekStart && timestampMs < bounds.weekEnd)
            || (timestampMs >= bounds.monthStart && timestampMs < bounds.monthEnd)
    }

    private struct WindowBounds {
        var sessionStart: Double
        var weekStart: Double
        var weekEnd: Double
        var monthStart: Double
        var monthEnd: Double
    }

    private static func windowBounds(nowMs: Double, anchorMs: Double?) -> WindowBounds {
        let weekStart = startOfUtcWeek(nowMs)
        let month = anchoredMonthBounds(nowMs: nowMs, anchorMs: anchorMs)
        return WindowBounds(
            sessionStart: nowMs - fiveHoursMs,
            weekStart: weekStart,
            weekEnd: weekStart + weekMs,
            monthStart: month.start,
            monthEnd: month.end
        )
    }

    private static func sumRange(_ costs: [(ms: Double, cost: Double)], start: Double, end: Double) -> Double {
        let total = costs.reduce(0.0) { partial, row in
            (row.ms >= start && row.ms < end) ? partial + row.cost : partial
        }
        // Snap to a hundredth of a cent to shed float-summation noise before the meter divides by the cap.
        return (total * 10000).rounded() / 10000
    }

    // MARK: - Week

    private static func startOfUtcWeek(_ nowMs: Double) -> Double {
        let startOfToday = utc.startOfDay(for: date(ms: nowMs))
        let weekday = utc.component(.weekday, from: startOfToday) // 1=Sun ... 7=Sat
        let daysSinceMonday = (weekday + 5) % 7                   // Mon→0, Sun→6
        let monday = utc.date(byAdding: .day, value: -daysSinceMonday, to: startOfToday) ?? startOfToday
        return ms(monday)
    }

    // MARK: - Month (anchored to earliest usage's day-of-month)

    private static func anchoredMonthBounds(nowMs: Double, anchorMs: Double?) -> (start: Double, end: Double) {
        guard let anchorMs, anchorMs.isFinite else {
            let components = utc.dateComponents([.year, .month], from: date(ms: nowMs))
            let start = utcDate(year: components.year!, month: components.month!, day: 1)
            let end = utcDate(year: components.year!, month: components.month! + 1, day: 1)
            return (ms(start), ms(end))
        }

        let anchor = date(ms: anchorMs)
        let nowComponents = utc.dateComponents([.year, .month], from: date(ms: nowMs))
        var year = nowComponents.year!
        var month = nowComponents.month! // 1-based
        var start = anchoredMonthStart(year: year, month: month, anchor: anchor)

        // The current calendar month's anchored start can land in the future (anchor day-of-month is later
        // than today) — then the live cycle actually started last month.
        if ms(start) > nowMs {
            (year, month) = shiftMonth(year: year, month: month, delta: -1)
            start = anchoredMonthStart(year: year, month: month, anchor: anchor)
        }
        let (nextYear, nextMonth) = shiftMonth(year: year, month: month, delta: 1)
        let end = anchoredMonthStart(year: nextYear, month: nextMonth, anchor: anchor)
        return (ms(start), ms(end))
    }

    /// The anchored cycle start within a given month: the anchor's day-of-month (clamped to the month's
    /// length) at the anchor's time-of-day, in UTC.
    private static func anchoredMonthStart(year: Int, month: Int, anchor: Date) -> Date {
        let anchorParts = utc.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: anchor)
        let day = min(anchorParts.day ?? 1, daysInMonth(year: year, month: month))
        return utcDate(
            year: year, month: month, day: day,
            hour: anchorParts.hour ?? 0, minute: anchorParts.minute ?? 0,
            second: anchorParts.second ?? 0, nanosecond: anchorParts.nanosecond ?? 0
        )
    }

    private static func shiftMonth(year: Int, month: Int, delta: Int) -> (year: Int, month: Int) {
        // `month` is 1-based; move to 0-based for the modular arithmetic, then back.
        let total = year * 12 + (month - 1) + delta
        let normalizedMonth = ((total % 12) + 12) % 12
        return (Int((Double(total) / 12).rounded(.down)), normalizedMonth + 1)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        let first = utcDate(year: year, month: month, day: 1)
        return utc.range(of: .day, in: .month, for: first)?.count ?? 28
    }

    private static func utcDate(
        year: Int, month: Int, day: Int,
        hour: Int = 0, minute: Int = 0, second: Int = 0, nanosecond: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month // Calendar normalizes out-of-range month/day (matches JS Date.UTC)
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        return utc.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private static func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }
    private static func date(ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}

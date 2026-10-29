import Foundation

/// Reads what Cursor charged on each of the last 30 local days from its usage events, a day at a time.
/// Today and yesterday are read again on every refresh; an older day is read until one read finishes it.
struct CursorSpendHistoryFetcher: Sendable {
    static let windowDays = 30

    var client: CursorUsageClient
    var budget: TimeInterval = 20
    var maxConcurrentDays = 4
    var pageSize = 1000

    struct Day: Sendable {
        var start: Date
        var end: Date
        var isComplete: Bool
    }

    private enum DayResult: Sendable {
        case read(Day, CursorSpendDay)
        case failed(String)
        case deadline
    }

    /// The last 30 local days, today first; today ends now.
    static func window(now: Date, calendar: Calendar) -> [Day] {
        let today = calendar.startOfDay(for: now)
        return (0..<windowDays).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: start)
            else { return nil }
            return Day(start: start, end: min(next, now), isComplete: next <= now)
        }
    }

    /// `days` with every day of `window` that was read in time filled in. Only complete days older than
    /// yesterday are kept from before; today, yesterday, and a day that fails or runs out of time stay unread.
    func refresh(
        _ days: [Date: CursorSpendDay],
        window: [Day],
        accessToken: String,
        calendar: Calendar,
        accountID: String
    ) async -> [Date: CursorSpendDay] {
        let starts = Set(window.map(\.start))
        var days = days.filter { starts.contains($0.key) && $0.value.isComplete && $0.key < window[1].start }
        var due = window.filter { days[$0.start] == nil }[...]
        var failures: [String] = []
        var deadlineHit = false

        await withTaskGroup(of: DayResult.self) { group in
            defer { group.cancelAll() }
            var reading = 0
            func readNext() {
                guard let day = due.popFirst() else { return }
                reading += 1
                group.addTask { await read(day, accessToken: accessToken, calendar: calendar) }
            }
            for _ in 0..<maxConcurrentDays { readNext() }
            group.addTask { [budget] in
                try? await Task.sleep(for: .seconds(budget))
                return .deadline
            }
            while reading > 0, let result = await group.next() {
                switch result {
                case .read(let day, let spend):
                    days[day.start] = spend
                case .failed(let reason):
                    failures.append(reason)
                case .deadline:
                    deadlineHit = true
                    return
                }
                reading -= 1
                readNext()
            }
        }

        guard !Task.isCancelled else { return days }
        if let first = failures.first {
            AppLog.warn(LogTag.plugin("cursor"), "\(accountID) spend history: \(failures.count) of \(window.count) days failed (\(first))")
        }
        if deadlineHit {
            let missing = window.filter { days[$0.start] == nil }.count
            AppLog.warn(LogTag.plugin("cursor"), "\(accountID) spend history: ran out of time with \(missing) of \(window.count) days missing")
        }
        return days
    }

    private func read(_ day: Day, accessToken: String, calendar: Calendar) async -> DayResult {
        let end = Date(timeIntervalSince1970: Double(Int(day.end.timeIntervalSince1970 * 1000) - 1) / 1000)
        var chargedCents = 0.0
        var received = 0
        var expectedTotal: Int?
        for page in 1... {
            let response: HTTPResponse
            do {
                guard let sent = try await client.fetchUsageEventsPage(
                    accessToken: accessToken, start: day.start, end: end, page: page, pageSize: pageSize
                ) else { return .failed("request could not be prepared from the current session") }
                response = sent
            } catch {
                return .failed("request failed")
            }
            guard (200..<300).contains(response.statusCode) else { return .failed("HTTP \(response.statusCode)") }
            guard let parsed = CursorUsageEvents.parsePage(response.body),
                  parsed.events.allSatisfy({ calendar.startOfDay(for: $0.date) == day.start })
            else { return .failed("invalid response") }
            guard expectedTotal ?? parsed.totalCount == parsed.totalCount else { return .failed("incomplete pages") }
            expectedTotal = parsed.totalCount
            received += parsed.events.count
            chargedCents += parsed.events.reduce(0) { $0 + $1.chargedCents }
            if received == parsed.totalCount {
                return .read(day, CursorSpendDay(chargedCents: chargedCents, isComplete: day.isComplete))
            }
            guard received < parsed.totalCount, !parsed.events.isEmpty else { return .failed("incomplete pages") }
        }
        return .failed("incomplete pages")
    }
}

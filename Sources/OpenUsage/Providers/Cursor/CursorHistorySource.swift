import Foundation

/// Reads Cursor's usage events a local day at a time: at most 4 days at once, for at most 20 seconds.
struct CursorHistorySource: UsageHistorySource {
    var client: CursorUsageClient
    var accessToken: String
    var accountID: String
    var budget: TimeInterval = 20
    var maxConcurrentDays = 4
    var pageSize = 1000

    private enum DayResult: Sendable {
        case read(Date, UsageDay)
        case failed(String)
        case deadline
    }

    func read(_ days: [Date], asOf: Date, calendar: Calendar) async -> [Date: UsageDay] {
        var due = days[...]
        var read: [Date: UsageDay] = [:]
        var failures: [String] = []
        var deadlineHit = false

        await withTaskGroup(of: DayResult.self) { group in
            defer { group.cancelAll() }
            var reading = 0
            func readNext() {
                guard let start = due.popFirst() else { return }
                reading += 1
                group.addTask { await readDay(start, asOf: asOf, calendar: calendar) }
            }
            for _ in 0..<maxConcurrentDays { readNext() }
            group.addTask { [budget] in
                try? await Task.sleep(for: .seconds(budget))
                return .deadline
            }
            while reading > 0, let result = await group.next() {
                switch result {
                case .read(let start, let day):
                    read[start] = day
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

        guard !Task.isCancelled else { return read }
        if let first = failures.first {
            AppLog.warn(LogTag.plugin("cursor"), "\(accountID) usage history: \(failures.count) of \(days.count) days failed (\(first))")
        }
        if deadlineHit {
            AppLog.warn(LogTag.plugin("cursor"), "\(accountID) usage history: ran out of time with \(days.count - read.count) of \(days.count) days missing")
        }
        return read
    }

    private func readDay(_ start: Date, asOf: Date, calendar: Calendar) async -> DayResult {
        guard let next = calendar.date(byAdding: .day, value: 1, to: start).map(calendar.startOfDay) else { return .failed("invalid day") }
        let end = Date(timeIntervalSince1970: Double(Int(min(next, asOf).timeIntervalSince1970 * 1000) - 1) / 1000)
        var events: [CursorUsageEvent] = []
        var expectedTotal: Int?
        for page in 1... {
            let response: HTTPResponse
            do {
                guard let sent = try await client.fetchUsageEventsPage(
                    accessToken: accessToken, start: start, end: end, page: page, pageSize: pageSize
                ) else { return .failed("request could not be prepared from the current session") }
                response = sent
            } catch {
                return .failed("request failed")
            }
            guard (200..<300).contains(response.statusCode) else { return .failed("HTTP \(response.statusCode)") }
            guard let parsed = CursorUsageEvents.parsePage(response.body),
                  parsed.events.allSatisfy({ calendar.startOfDay(for: $0.date) == start })
            else { return .failed("invalid response") }
            guard expectedTotal ?? parsed.totalCount == parsed.totalCount else { return .failed("incomplete pages") }
            expectedTotal = parsed.totalCount
            events += parsed.events
            if events.count == parsed.totalCount {
                return .read(start, CursorUsageEvents.day(events))
            }
            guard events.count < parsed.totalCount, !parsed.events.isEmpty else { return .failed("incomplete pages") }
        }
        return .failed("incomplete pages")
    }
}

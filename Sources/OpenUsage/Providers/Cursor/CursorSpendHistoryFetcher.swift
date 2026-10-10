import Foundation

struct CursorSpendHistoryFetcher: Sendable {
    var client: CursorUsageClient
    var store: CursorUsageHistoryStore
    var budget: TimeInterval
    var maxConcurrentDays = 4
    var pageSize = 1000

    private enum DayTaskResult: Sendable {
        case success(key: String, dayStart: Date, day: CursorUsageDay)
        case failure(reason: FailureReason)
        case deadline
    }

    private enum FailureReason: Sendable {
        case http(Int)
        case request
        case invalidResponse
        case incompletePages

        var logText: String {
            switch self {
            case .http(let status): "HTTP \(status)"
            case .request: "request failed"
            case .invalidResponse: "invalid response"
            case .incompletePages: "incomplete pages"
            }
        }
    }

    func refresh(accessToken: String, userID: String, now: Date) async -> [(dayStart: Date, day: CursorUsageDay)]? {
        var localCalendar = Calendar.current
        localCalendar.timeZone = .current
        let calendar = localCalendar
        let today = calendar.startOfDay(for: now)
        let window = (0..<30).compactMap { offset -> (key: String, start: Date, end: Date)? in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: start)
            else {
                return nil
            }
            return (
                DailyUsageAccumulator.dayKey(from: start, calendar: calendar),
                start,
                min(nextDay, now)
            )
        }
        let timeZone = calendar.timeZone.identifier
        var cached = store.load(userID: userID, timeZone: timeZone)
        let windowKeys = Set(window.map(\.key))
        cached = cached.filter { windowKeys.contains($0.key) }
        let daysToFetch = window.enumerated().compactMap { index, day in
            index < 2 || cached[day.key] == nil ? day : nil
        }

        var failures = 0
        var successfulDays = 0
        var firstFailure: FailureReason?
        var deadlineHit = false

        await withTaskGroup(of: DayTaskResult.self) { group in
            var nextDayIndex = 0
            var activeDays = 0
            for _ in 0..<min(maxConcurrentDays, daysToFetch.count) {
                let day = daysToFetch[nextDayIndex]
                nextDayIndex += 1
                activeDays += 1
                group.addTask {
                    await fetchDay(
                        accessToken: accessToken,
                        dayKey: day.key,
                        dayStart: day.start,
                        dayEnd: day.end,
                        calendar: calendar
                    )
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(budget))
                return .deadline
            }
            defer { group.cancelAll() }

            while let result = await group.next() {
                switch result {
                case .success(let key, _, let day):
                    activeDays -= 1
                    successfulDays += 1
                    cached[key] = day
                    if nextDayIndex < daysToFetch.count {
                        let nextDay = daysToFetch[nextDayIndex]
                        nextDayIndex += 1
                        activeDays += 1
                        group.addTask {
                            await fetchDay(
                                accessToken: accessToken,
                                dayKey: nextDay.key,
                                dayStart: nextDay.start,
                                dayEnd: nextDay.end,
                                calendar: calendar
                            )
                        }
                    }
                case .failure(let reason):
                    activeDays -= 1
                    failures += 1
                    if firstFailure == nil { firstFailure = reason }
                    if nextDayIndex < daysToFetch.count {
                        let nextDay = daysToFetch[nextDayIndex]
                        nextDayIndex += 1
                        activeDays += 1
                        group.addTask {
                            await fetchDay(
                                accessToken: accessToken,
                                dayKey: nextDay.key,
                                dayStart: nextDay.start,
                                dayEnd: nextDay.end,
                                calendar: calendar
                            )
                        }
                    }
                case .deadline:
                    deadlineHit = true
                    group.cancelAll()
                    return
                }
                if activeDays == 0 && nextDayIndex == daysToFetch.count {
                    return
                }
            }
        }

        if failures > 0, let firstFailure {
            AppLog.warn(
                LogTag.plugin("cursor"),
                "usage events: \(failures) day\(failures == 1 ? "" : "s") failed (\(firstFailure.logText))"
            )
        }
        if deadlineHit {
            let missingCount = window.filter { cached[$0.key] == nil }.count
            AppLog.warn(LogTag.plugin("cursor"), "usage events: deadline hit with \(missingCount) of \(window.count) days still missing")
        }

        if successfulDays > 0 {
            store.save(cached, userID: userID, timeZone: timeZone)
        }
        guard window.allSatisfy({ cached[$0.key] != nil }) else { return nil }
        return window.compactMap { day in
            cached[day.key].map { (dayStart: day.start, day: $0) }
        }
    }

    private func fetchDay(
        accessToken: String,
        dayKey: String,
        dayStart: Date,
        dayEnd: Date,
        calendar: Calendar
    ) async -> DayTaskResult {
        let endMilliseconds = Int(dayEnd.timeIntervalSince1970 * 1000) - 1
        let end = Date(timeIntervalSince1970: Double(endMilliseconds) / 1000)
        var pageNumber = 1
        var expectedTotal: Int?
        var receivedCount = 0
        var day = CursorUsageDay(models: [:])

        while true {
            do {
                guard let response = try await client.fetchUsageEventsPage(
                    accessToken: accessToken,
                    start: dayStart,
                    end: end,
                    page: pageNumber,
                    pageSize: pageSize
                ) else {
                    return .failure(reason: .request)
                }
                guard (200..<300).contains(response.statusCode) else {
                    return .failure(reason: .http(response.statusCode))
                }
                let parsed: CursorUsageEventsPage
                do {
                    parsed = try CursorUsageEvents.parsePage(response.body)
                } catch {
                    return .failure(reason: .invalidResponse)
                }
                if let expectedTotal, parsed.totalCount != expectedTotal {
                    return .failure(reason: .incompletePages)
                }
                expectedTotal = parsed.totalCount
                let pageEventCount = parsed.events.count + parsed.rejectedEventCount
                receivedCount += pageEventCount
                if parsed.rejectedEventCount > 0 {
                    AppLog.warn(
                        LogTag.plugin("cursor"),
                        "usage events: \(parsed.rejectedEventCount) rejected event\(parsed.rejectedEventCount == 1 ? "" : "s") on one page"
                    )
                }
                if parsed.totalCount == 0 {
                    return pageEventCount == 0
                        ? .success(key: dayKey, dayStart: dayStart, day: day)
                        : .failure(reason: .incompletePages)
                }
                if pageEventCount == 0 && receivedCount < parsed.totalCount {
                    return .failure(reason: .incompletePages)
                }
                for event in parsed.events {
                    let eventDay = DailyUsageAccumulator.dayKey(from: event.date, calendar: calendar)
                    guard eventDay == dayKey else {
                        return .failure(reason: .invalidResponse)
                    }
                    day.add(event.tokens, for: event.model)
                }
                if receivedCount == parsed.totalCount {
                    return .success(key: dayKey, dayStart: dayStart, day: day)
                }
                if receivedCount > parsed.totalCount {
                    return .failure(reason: .incompletePages)
                }
                pageNumber += 1
            } catch {
                return .failure(reason: .request)
            }
        }
    }
}

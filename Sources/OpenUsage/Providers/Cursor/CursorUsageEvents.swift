import CoreFoundation
import Foundation

struct CursorUsageRow: Sendable, Equatable {
    var date: Date
    var model: String
    var tokens: TokenBreakdown
    var imputedCostDollars: Double?
}

struct CursorUsageEventsPage: Sendable, Equatable {
    var events: [CursorUsageEvent]
    var totalCount: Int
    var rejectedEventCount: Int
}

struct CursorUsageEvent: Sendable, Equatable {
    var date: Date
    var model: String
    var tokens: TokenBreakdown
}

enum CursorUsageEventsError: Error, Equatable {
    case invalidResponse
}

enum CursorUsageEvents {
    static func parsePage(_ data: Data) throws -> CursorUsageEventsPage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let totalCount = integer(object["totalUsageEventsCount"]),
              totalCount >= 0,
              let rawEvents = object["usageEventsDisplay"] as? [Any]
        else {
            throw CursorUsageEventsError.invalidResponse
        }

        var events: [CursorUsageEvent] = []
        var rejectedEventCount = 0
        for rawEvent in rawEvents {
            guard let event = rawEvent as? [String: Any],
                  let timestamp = date(event["timestamp"]),
                  let model = event["model"] as? String,
                  let tokens = tokenBreakdown(event["tokenUsage"])
            else {
                rejectedEventCount += 1
                continue
            }
            events.append(CursorUsageEvent(
                date: timestamp,
                model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                tokens: tokens
            ))
        }
        return CursorUsageEventsPage(
            events: events,
            totalCount: totalCount,
            rejectedEventCount: rejectedEventCount
        )
    }

    private static func tokenBreakdown(_ raw: Any?) -> TokenBreakdown? {
        guard let raw else { return TokenBreakdown() }
        guard let usage = raw as? [String: Any] else { return nil }
        guard let input = tokenValue(usage, key: "inputTokens"),
              let output = tokenValue(usage, key: "outputTokens"),
              let cacheWrite = tokenValue(usage, key: "cacheWriteTokens"),
              let cacheRead = tokenValue(usage, key: "cacheReadTokens")
        else {
            return nil
        }
        return TokenBreakdown(input: input, cacheWrite5m: cacheWrite, cacheRead: cacheRead, output: output)
    }

    private static func tokenValue(_ usage: [String: Any], key: String) -> Int? {
        guard let value = usage[key] else { return 0 }
        guard let integer = integer(value), integer >= 0 else { return nil }
        return integer
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value else { return nil }
        let milliseconds: Int?
        if let string = value as? String {
            milliseconds = Int(string)
        } else {
            milliseconds = integer(value)
        }
        guard let milliseconds, milliseconds >= 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.compare(NSNumber(value: Int.min)) != .orderedAscending,
              number.compare(NSNumber(value: Int.max)) != .orderedDescending
        else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double else {
            return nil
        }
        let integer = number.intValue
        guard NSNumber(value: integer).compare(number) == .orderedSame else { return nil }
        return integer
    }
}

import Foundation

/// What Cursor charged on one local day: the sum of `chargedCents` on that day's chargeable usage events.
struct CursorSpendDay: Sendable, Equatable {
    var chargedCents: Double
    /// False for today, whose events are still coming in.
    var isComplete: Bool
}

struct CursorUsageEventsPage: Sendable, Equatable {
    var totalCount: Int
    var events: [CursorChargedEvent]
}

struct CursorChargedEvent: Sendable, Equatable {
    var date: Date
    /// The event's `chargedCents` when Cursor bills it, else 0.
    var chargedCents: Double
}

enum CursorUsageEvents {
    /// On-demand usage, the only kind Cursor bills. Included, errored, and free events carry a
    /// `chargedCents` too, but for them it is the value taken from the plan, not a charge.
    static let chargeableKind = "USAGE_EVENT_KIND_USAGE_BASED"

    /// Nil when the page or any event on it is not what Cursor sends, so a day is never summed from part
    /// of its events. Cursor leaves out an empty event list, and a zero `chargedCents`.
    static func parsePage(_ data: Data) -> CursorUsageEventsPage? {
        guard let object = ProviderParse.jsonObject(data),
              let total = ProviderParse.number(object["totalUsageEventsCount"]),
              total >= 0, total.rounded() == total, total < 1e15
        else { return nil }
        guard let rawEvents = (object["usageEventsDisplay"] ?? [Any]()) as? [Any] else { return nil }

        var events: [CursorChargedEvent] = []
        for rawEvent in rawEvents {
            guard let event = rawEvent as? [String: Any],
                  let milliseconds = ProviderParse.number(event["timestamp"]), milliseconds >= 0
            else { return nil }
            var chargedCents = 0.0
            if event["kind"] as? String == chargeableKind, event["isChargeable"] as? Bool != false,
               let rawCents = event["chargedCents"] {
                guard let cents = ProviderParse.number(rawCents), cents >= 0 else { return nil }
                chargedCents = cents
            }
            events.append(CursorChargedEvent(date: Date(timeIntervalSince1970: milliseconds / 1000), chargedCents: chargedCents))
        }
        return CursorUsageEventsPage(totalCount: Int(total), events: events)
    }

    /// Today, Yesterday, and Last 30 Days in dollars, each only once every day it covers has been read.
    /// `window` is the local day starts to cover, today first.
    static func spendLines(_ days: [Date: CursorSpendDay], window: [Date]) -> [MetricLine] {
        func line(_ label: String, _ starts: ArraySlice<Date>) -> MetricLine? {
            let cents = starts.compactMap { days[$0]?.chargedCents }
            guard !starts.isEmpty, cents.count == starts.count else { return nil }
            return .values(label: label, values: [MetricValue(number: cents.reduce(0, +) / 100, kind: .dollars)])
        }
        return [
            line("Today", window.prefix(1)),
            line("Yesterday", window.dropFirst().prefix(1)),
            line("Last 30 Days", window[...])
        ].compactMap { $0 }
    }
}

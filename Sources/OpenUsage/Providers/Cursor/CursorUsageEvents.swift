import Foundation

struct CursorUsageEventsPage: Sendable, Equatable {
    var totalCount: Int
    var events: [CursorUsageEvent]
}

struct CursorUsageEvent: Sendable, Equatable {
    var date: Date
    var model: String?
    var totals: UsageTotals
}

enum CursorUsageEvents {
    /// On-demand usage, the only kind Cursor bills. Included, errored, and free events carry a
    /// `chargedCents` too, but for them it is the value taken from the plan, not a charge.
    static let chargeableKind = "USAGE_EVENT_KIND_USAGE_BASED"
    static let measures: [UsageMeasure] = [.spend, .usageEvents, .tokens, .inputTokens, .cacheReadTokens, .cacheWriteTokens, .outputTokens]
    private static let tokenKinds: [(field: String, measure: UsageMeasure)] = [
        ("inputTokens", .inputTokens), ("cacheReadTokens", .cacheReadTokens),
        ("cacheWriteTokens", .cacheWriteTokens), ("outputTokens", .outputTokens)
    ]

    /// Nil when the page or any event on it is not what Cursor sends, so a day is never summed from part
    /// of its events. Cursor leaves out an empty event list, a zero `chargedCents`, and a zero token kind.
    /// An event without `tokenUsage` reports no tokens.
    static func parsePage(_ data: Data) -> CursorUsageEventsPage? {
        guard let object = ProviderParse.jsonObject(data),
              let total = ProviderParse.number(object["totalUsageEventsCount"]),
              total >= 0, total.rounded() == total, total < 1e15
        else { return nil }
        guard let rawEvents = (object["usageEventsDisplay"] ?? [Any]()) as? [Any] else { return nil }

        var events: [CursorUsageEvent] = []
        for rawEvent in rawEvents {
            guard let event = rawEvent as? [String: Any],
                  let milliseconds = ProviderParse.number(event["timestamp"]), milliseconds >= 0
            else { return nil }
            var totals = UsageTotals(values: [.spend: 0, .usageEvents: 1])
            if event["kind"] as? String == chargeableKind, event["isChargeable"] as? Bool != false,
               let rawCents = event["chargedCents"] {
                guard let cents = ProviderParse.number(rawCents), cents >= 0 else { return nil }
                totals.values[.spend] = cents / 100
            }
            if let rawUsage = event["tokenUsage"] {
                guard let usage = rawUsage as? [String: Any] else { return nil }
                var tokens = 0.0
                for kind in tokenKinds {
                    var count = 0.0
                    if let rawCount = usage[kind.field] {
                        guard let parsed = ProviderParse.number(rawCount), parsed >= 0 else { return nil }
                        count = parsed
                    }
                    totals.values[kind.measure] = count
                    tokens += count
                }
                totals.values[.tokens] = tokens
            }
            events.append(CursorUsageEvent(
                date: Date(timeIntervalSince1970: milliseconds / 1000), model: event["model"] as? String, totals: totals
            ))
        }
        return CursorUsageEventsPage(totalCount: Int(total), events: events)
    }

    /// One day's events summed: a day with no events reports zeros, and a day where any event has no
    /// `tokenUsage` reports no tokens.
    static func day(_ events: [CursorUsageEvent]) -> UsageDay {
        func sum(_ events: [CursorUsageEvent]) -> UsageTotals {
            events.reduce(.zero(measures)) { $0.adding($1.totals) }
        }
        let byModel = events.allSatisfy { $0.model != nil }
            ? Dictionary(grouping: events) { $0.model ?? "" }.mapValues(sum)
            : nil
        return UsageDay(totals: sum(events), byModel: byModel)
    }
}

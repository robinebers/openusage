import Foundation

/// One quantity a provider reports for a span. Never estimated, never priced.
enum UsageMeasure: Hashable, Sendable, CaseIterable {
    case spend
    /// Spend on the user's own provider keys; never added to `spend`.
    case byokSpend
    case usageValue
    case usageEvents
    case requests
    case tokens
    case inputTokens
    case cacheReadTokens
    case cacheWriteTokens
    case outputTokens
    case reasoningTokens

    var title: String {
        switch self {
        case .spend: "Charged"
        case .byokSpend: "BYOK"
        case .usageValue: "Usage Value"
        case .usageEvents: "Usage Events"
        case .requests: "Requests"
        case .tokens: "Tokens"
        case .inputTokens: "Input Tokens"
        case .cacheReadTokens: "Cache Read Tokens"
        case .cacheWriteTokens: "Cache Write Tokens"
        case .outputTokens: "Output Tokens"
        case .reasoningTokens: "Reasoning Tokens"
        }
    }

    func metricValue(_ number: Double) -> MetricValue {
        switch self {
        case .spend, .usageValue: MetricValue(number: number, kind: .dollars)
        case .byokSpend: MetricValue(number: number, kind: .dollars, label: "BYOK")
        case .usageEvents: MetricValue(number: number, kind: .count, label: "events")
        case .requests: MetricValue(number: number, kind: .count, label: "requests")
        case .tokens, .inputTokens, .cacheReadTokens, .cacheWriteTokens, .outputTokens, .reasoningTokens:
            MetricValue(number: number, kind: .count, label: "tokens")
        }
    }
}

/// The measures a provider reported for one span. A missing measure was not reported, which is never zero.
struct UsageTotals: Hashable, Sendable {
    var values: [UsageMeasure: Double] = [:]

    static func zero(_ measures: [UsageMeasure]) -> UsageTotals {
        UsageTotals(values: Dictionary(uniqueKeysWithValues: measures.map { ($0, 0) }))
    }

    subscript(_ measure: UsageMeasure) -> Double? { values[measure] }

    /// Keeps a measure only when both report it, so a sum is never an undercount.
    func adding(_ other: UsageTotals) -> UsageTotals {
        UsageTotals(values: values.reduce(into: [:]) { sum, entry in
            if let addend = other.values[entry.key] { sum[entry.key] = entry.value + addend }
        })
    }
}

struct UsageDay: Hashable, Sendable {
    var totals: UsageTotals
    /// Nil unless the provider named the model of every event of the day.
    var byModel: [String: UsageTotals]?
}

enum UsageWindow: Hashable, Sendable {
    case today
    case yesterday
    /// Today and the days before it.
    case lastDays(Int)
    /// The days before today.
    case priorDays(Int)
    /// Windows only a provider's own totals cover; weeks start on Monday.
    case thisWeek
    case thisMonth

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastDays(let count): "Last \(count) Days"
        case .priorDays(let count): "Prior \(count) Days"
        case .thisWeek: "This Week"
        case .thisMonth: "This Month"
        }
    }

    var phrase: String {
        switch self {
        case .today: "today"
        case .yesterday: "yesterday"
        case .lastDays(let count): "in \(count) days"
        case .priorDays(let count): "in prior \(count) days"
        case .thisWeek: "this week"
        case .thisMonth: "this month"
        }
    }

    /// Which days the window covers: the user's own, or UTC days for a provider that reports those.
    func clockNote(in calendar: Calendar) -> String {
        let clock = calendar.timeZone == TimeZone(identifier: "UTC") ? "UTC" : "your local"
        return switch self {
        case .today, .yesterday: "\(clock) day"
        case .lastDays, .priorDays: "\(clock) days"
        case .thisWeek: "\(clock) week from Monday"
        case .thisMonth: "\(clock) month"
        }
    }

    /// Nil for a window only the provider's own totals cover.
    var dayOffsets: ClosedRange<Int>? {
        switch self {
        case .today: 0...0
        case .yesterday: 1...1
        case .lastDays(let count): 0...(count - 1)
        case .priorDays(let count): 1...count
        case .thisWeek, .thisMonth: nil
        }
    }
}

/// Usage a provider reported per local day, as of one moment.
struct UsageHistory: Hashable, Sendable {
    let calendar: Calendar
    let asOf: Date
    /// Keyed by day start; a day that is absent was not read.
    var days: [Date: UsageDay] = [:]
    /// A window's totals as the provider reported them, which win over a sum of days.
    var reported: [UsageWindow: UsageTotals] = [:]

    /// The starts of the days `offsets` back from the day holding `now`.
    static func dayStarts(_ offsets: some Sequence<Int>, now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return offsets.compactMap { calendar.date(byAdding: .day, value: -$0, to: today).map(calendar.startOfDay) }
    }

    /// Nil when any day of the window is unread.
    func totals(over window: UsageWindow) -> UsageTotals? {
        if let reported = reported[window] { return reported }
        guard let days = days(in: window), let first = days.first else { return nil }
        return days.dropFirst().reduce(first.totals) { $0.adding($1.totals) }
    }

    /// Nil unless every day of the window was read and split by model.
    func models(over window: UsageWindow) -> [String: UsageTotals]? {
        guard let days = days(in: window) else { return nil }
        var models: [String: UsageTotals] = [:]
        for day in days {
            guard let byModel = day.byModel else { return nil }
            for (name, totals) in byModel {
                models[name] = models[name].map { $0.adding(totals) } ?? totals
            }
        }
        return models
    }

    private func days(in window: UsageWindow) -> [UsageDay]? {
        guard let offsets = window.dayOffsets else { return nil }
        let read = Self.dayStarts(offsets, now: asOf, calendar: calendar).compactMap { days[$0] }
        return read.count == offsets.count ? read : nil
    }
}

/// What a window's hover detail shows: every measure the provider reported for it, and its top models.
struct UsageBreakdown: Hashable, Sendable {
    struct Model: Hashable, Sendable {
        let name: String
        let number: Double
        let share: Double
    }

    static let shownModels = 5

    let window: UsageWindow
    let clockNote: String
    let totals: UsageTotals
    /// Tokens, else usage events or requests, whichever every model reported.
    let modelMeasure: UsageMeasure
    /// The top models by `modelMeasure`, the rest as Other; empty unless every day was split by model.
    let models: [Model]

    init?(_ window: UsageWindow, in history: UsageHistory) {
        guard let totals = history.totals(over: window) else { return nil }
        let models = history.models(over: window) ?? [:]
        let measure = [UsageMeasure.tokens, .usageEvents, .requests].first { measure in
            models.values.allSatisfy { $0[measure] != nil }
        } ?? .tokens
        let ranked = models.compactMap { name, totals in totals[measure].map { (name: name, number: $0) } }
            .sorted { $0.number != $1.number ? $0.number > $1.number : $0.name < $1.name }
        let whole = ranked.reduce(0) { $0 + $1.number }
        var shown = Array(ranked.prefix(Self.shownModels))
        if ranked.count > Self.shownModels {
            shown.append((name: "Other", number: ranked.dropFirst(Self.shownModels).reduce(0) { $0 + $1.number }))
        }
        self.window = window
        clockNote = window.clockNote(in: history.calendar)
        self.totals = totals
        modelMeasure = measure
        self.models = shown.map { Model(name: $0.name, number: $0.number, share: whole > 0 ? $0.number / whole : 0) }
    }
}

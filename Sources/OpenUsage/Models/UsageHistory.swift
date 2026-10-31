import Foundation

/// One quantity a provider reports for a span. Never estimated, never priced.
enum UsageMeasure: Hashable, Sendable, CaseIterable {
    case spend
    case usageEvents
    case tokens
    case inputTokens
    case cacheReadTokens
    case cacheWriteTokens
    case outputTokens

    var title: String {
        switch self {
        case .spend: "Charged"
        case .usageEvents: "Usage Events"
        case .tokens: "Tokens"
        case .inputTokens: "Input Tokens"
        case .cacheReadTokens: "Cache Read Tokens"
        case .cacheWriteTokens: "Cache Write Tokens"
        case .outputTokens: "Output Tokens"
        }
    }

    func metricValue(_ number: Double) -> MetricValue {
        switch self {
        case .spend: MetricValue(number: number, kind: .dollars)
        case .usageEvents: MetricValue(number: number, kind: .count, label: "events")
        case .tokens, .inputTokens, .cacheReadTokens, .cacheWriteTokens, .outputTokens:
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

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastDays(let count): "Last \(count) Days"
        }
    }

    var phrase: String {
        switch self {
        case .today: "today"
        case .yesterday: "yesterday"
        case .lastDays(let count): "in \(count) days"
        }
    }

    var clockNote: String {
        switch self {
        case .today, .yesterday: "your local day"
        case .lastDays: "your local days"
        }
    }

    var dayOffsets: ClosedRange<Int> {
        switch self {
        case .today: 0...0
        case .yesterday: 1...1
        case .lastDays(let count): 0...(count - 1)
        }
    }
}

/// Usage a provider reported per local day, as of one moment.
struct UsageHistory: Hashable, Sendable {
    let calendar: Calendar
    let asOf: Date
    /// Keyed by day start; a day that is absent was not read.
    var days: [Date: UsageDay] = [:]

    /// The starts of the days `offsets` back from the day holding `now`.
    static func dayStarts(_ offsets: some Sequence<Int>, now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return offsets.compactMap { calendar.date(byAdding: .day, value: -$0, to: today).map(calendar.startOfDay) }
    }

    /// Nil when any day of the window is unread.
    func totals(over window: UsageWindow) -> UsageTotals? {
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
        let read = Self.dayStarts(window.dayOffsets, now: asOf, calendar: calendar).compactMap { days[$0] }
        return read.count == window.dayOffsets.count ? read : nil
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
    let totals: UsageTotals
    /// Tokens, or usage events when a model's tokens were not reported.
    let modelMeasure: UsageMeasure
    /// The top models by `modelMeasure`, the rest as Other; empty unless every day was split by model.
    let models: [Model]

    init?(_ window: UsageWindow, in history: UsageHistory) {
        guard let totals = history.totals(over: window) else { return nil }
        let models = history.models(over: window) ?? [:]
        let measure: UsageMeasure = models.values.allSatisfy { $0[.tokens] != nil } ? .tokens : .usageEvents
        let ranked = models.compactMap { name, totals in totals[measure].map { (name: name, number: $0) } }
            .sorted { $0.number != $1.number ? $0.number > $1.number : $0.name < $1.name }
        let whole = ranked.reduce(0) { $0 + $1.number }
        var shown = Array(ranked.prefix(Self.shownModels))
        if ranked.count > Self.shownModels {
            shown.append((name: "Other", number: ranked.dropFirst(Self.shownModels).reduce(0) { $0 + $1.number }))
        }
        self.window = window
        self.totals = totals
        modelMeasure = measure
        self.models = shown.map { Model(name: $0.name, number: $0.number, share: whole > 0 ? $0.number / whole : 0) }
    }
}

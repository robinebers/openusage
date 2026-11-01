import Foundation

/// One quantity a provider reports for a span. Never estimated, never priced.
enum UsageMeasure: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case spend
    /// Spend on the user's own provider keys; never added to `spend`.
    case byokSpend
    case usageValue
    case credits
    case usageEvents
    case requests
    case turns
    case tokens
    case inputTokens
    case cacheReadTokens
    case cacheWriteTokens
    case outputTokens
    case reasoningTokens

    /// The kinds of token a provider may split its total into, with their short names.
    static let tokenParts: [(measure: UsageMeasure, title: String)] = [
        (.inputTokens, "Input"), (.cacheReadTokens, "Cache Read"), (.cacheWriteTokens, "Cache Write"),
        (.outputTokens, "Output"), (.reasoningTokens, "Reasoning"),
    ]

    func metricValue(_ number: Double) -> MetricValue {
        switch self {
        case .spend, .usageValue: MetricValue(number: number, kind: .dollars)
        case .byokSpend: MetricValue(number: number, kind: .dollars, label: "BYOK")
        case .credits: MetricValue(number: number, kind: .count, label: "credits")
        case .usageEvents: MetricValue(number: number, kind: .count, label: "events")
        case .requests: MetricValue(number: number, kind: .count, label: "requests")
        case .turns: MetricValue(number: number, kind: .count, label: "turns")
        case .tokens, .inputTokens, .cacheReadTokens, .cacheWriteTokens, .outputTokens, .reasoningTokens:
            MetricValue(number: number, kind: .count, label: "tokens")
        }
    }
}

/// The measures a provider reported for one span. A missing measure was not reported, which is never zero.
struct UsageTotals: Codable, Hashable, Sendable {
    var values: [UsageMeasure: Double] = [:]

    static func zero(_ measures: [UsageMeasure]) -> UsageTotals {
        UsageTotals(values: Dictionary(uniqueKeysWithValues: measures.map { ($0, 0) }))
    }

    subscript(_ measure: UsageMeasure) -> Double? { values[measure] }

    /// Sums what either reports, so a day missing a measure doesn't cost the range the rest of it.
    func adding(_ other: UsageTotals) -> UsageTotals {
        UsageTotals(values: values.merging(other.values, uniquingKeysWith: +))
    }
}

struct UsageDay: Hashable, Sendable {
    var totals: UsageTotals
    /// What the provider reported by model for the day; nil when it named none.
    var byModel: [String: UsageTotals]?
}

enum UsageWindow: Codable, Hashable, Sendable {
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

    var noUsageTitle: String {
        switch self {
        case .today: "No Usage Today"
        case .yesterday: "No Usage Yesterday"
        case .lastDays(let count): "No Usage in \(count) Days"
        case .priorDays(let count): "No Usage in Prior \(count) Days"
        case .thisWeek: "No Usage This Week"
        case .thisMonth: "No Usage This Month"
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

    /// The sum of the window's days that have been read; nil when none has.
    func totals(over window: UsageWindow) -> UsageTotals? {
        if let reported = reported[window] { return reported }
        let days = days(in: window)
        guard let first = days.first else { return nil }
        return days.dropFirst().reduce(first.totals) { $0.adding($1.totals) }
    }

    /// What the window's days report by model, added up.
    func models(over window: UsageWindow) -> [String: UsageTotals] {
        var models: [String: UsageTotals] = [:]
        for day in days(in: window) {
            for (name, totals) in day.byModel ?? [:] {
                models[name] = models[name].map { $0.adding(totals) } ?? totals
            }
        }
        return models
    }

    private func days(in window: UsageWindow) -> [UsageDay] {
        guard let offsets = window.dayOffsets else { return [] }
        return Self.dayStarts(offsets, now: asOf, calendar: calendar).compactMap { days[$0] }
    }
}

/// What Top Models shows and ranks by.
enum ModelFigure: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case cost
    case tokens
    /// A model's part of the range's credits or turns, for a provider with no dollars or tokens by model.
    case share

    static let key = "usageBreakdownModelFigure"

    var label: String {
        switch self {
        case .cost: "Cost"
        case .tokens: "Tokens"
        case .share: "Share"
        }
    }

    func text(_ number: Double) -> String {
        switch self {
        case .cost: MetricFormatter.number(number, kind: .dollars, style: .row)
        case .tokens: MetricFormatter.number(number, kind: .count, style: .row)
        case .share: "\(Int((number * 100).rounded()))%"
        }
    }
}

/// What a window's hover detail shows: what it charged, its tokens by kind, and its top models.
struct UsageBreakdown: Codable, Hashable, Sendable {
    struct Model: Codable, Hashable, Sendable {
        let name: String
        let dollars: Double?
        let tokens: Double?
        let share: Double?

        func number(_ figure: ModelFigure) -> Double? {
            switch figure {
            case .cost: dollars
            case .tokens: tokens
            case .share: share
            }
        }
    }

    struct TokenPart: Hashable, Sendable {
        let title: String
        let number: Double
    }

    static let shownModels = 5
    private static let dollarMeasures: [UsageMeasure] = [.spend, .usageValue]

    let window: UsageWindow
    private let reportingDay: Date
    private let reportingTimeZone: TimeZone
    let totals: UsageTotals
    /// Only the names and figures shown in the popover are kept with the snapshot.
    private let rankings: [ModelFigure: [Model]]
    /// What the models report, in order of preference. Credits or turns supply a share when neither
    /// dollars nor tokens were reported by model.
    var modelFigures: [ModelFigure] { ModelFigure.allCases.filter { rankings[$0] != nil } }

    init?(_ window: UsageWindow, in history: UsageHistory) {
        guard let totals = history.totals(over: window) else { return nil }
        let models = history.models(over: window)
        func isReported(_ measure: UsageMeasure) -> Bool {
            models.values.contains { ($0[measure] ?? 0) > 0 }
        }
        let dollars = Self.dollarMeasures.first(where: isReported)
        let hasTokens = isReported(.tokens)
        let share = [UsageMeasure.credits, .turns].first(where: isReported)
        let shareTotal = share.map { measure in models.values.compactMap { $0[measure] }.filter { $0 > 0 }.reduce(0, +) } ?? 0

        self.window = window
        reportingDay = history.calendar.startOfDay(for: history.asOf)
        reportingTimeZone = history.calendar.timeZone
        self.totals = totals
        let everyModel = models.map { name, model in
            Model(
                name: name,
                dollars: dollars.flatMap { model[$0] },
                tokens: hasTokens ? model[.tokens] : nil,
                share: share.flatMap { model[$0] }.map { max($0, 0) / shareTotal }
            )
        }
        let figures: [ModelFigure] = (dollars == nil ? [] : [.cost]) + (hasTokens ? [.tokens] : [])
        let available: [ModelFigure] = figures.isEmpty && share != nil ? [.share] : figures
        rankings = Dictionary(uniqueKeysWithValues: available.map { ($0, Self.rank(everyModel, by: $0)) })
    }

    /// Relative window names expire at midnight on the source's clock.
    func archivedTitle(at now: Date = Date()) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = reportingTimeZone
        guard !calendar.isDate(reportingDay, inSameDayAs: now),
              let end = calendar.date(byAdding: .day, value: -(window.dayOffsets?.lowerBound ?? 0), to: reportingDay)
        else { return nil }
        let date = end.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: reportingTimeZone))
        switch window {
        case .today, .yesterday: return date
        case .lastDays(let count), .priorDays(let count): return "\(count) Days Ending \(date)"
        case .thisWeek: return "Week Through \(date)"
        case .thisMonth: return "Month Through \(date)"
        }
    }

    func models(by figure: ModelFigure) -> [Model] { rankings[figure] ?? [] }

    /// The top models by `figure`, the rest as Other.
    private static func rank(_ models: [Model], by figure: ModelFigure) -> [Model] {
        let ranked = models.filter { $0.number(figure) != nil }.sorted {
            let (left, right) = ($0.number(figure) ?? 0, $1.number(figure) ?? 0)
            return left != right ? left > right : $0.name < $1.name
        }
        let rest = ranked.dropFirst(Self.shownModels)
        guard !rest.isEmpty else { return ranked }
        func sum(_ number: (Model) -> Double?) -> Double? {
            let values = rest.compactMap(number)
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        return ranked.prefix(Self.shownModels) + [Model(name: "Other", dollars: sum(\.dollars), tokens: sum(\.tokens), share: sum(\.share))]
    }

    /// Zero spend alone cannot rule out free requests.
    var isEmpty: Bool {
        [UsageMeasure.tokens, .requests, .turns, .usageEvents].contains { totals[$0] != nil }
            && totals.values.values.allSatisfy { $0 == 0 }
    }

    /// The window has a total, but nothing to break it down by.
    var isTotalsOnly: Bool { !isEmpty && tokenParts.isEmpty && modelFigures.isEmpty }

    /// What the window charged, then its tokens and any spend on the user's own keys. A window that
    /// reports neither dollars nor tokens falls back to the first thing it does report.
    var figures: [String] {
        let charged = Self.dollarMeasures.first { totals[$0] != nil }
        let shown = [charged, .tokens, .byokSpend].compactMap(\.self).filter { measure in
            guard let number = totals[measure] else { return false }
            return measure != .byokSpend || number > 0
        }
        let measures = shown.isEmpty ? Array(UsageMeasure.allCases.filter { totals[$0] != nil }.prefix(1)) : shown
        return measures.compactMap { measure in
            totals[measure].map { MetricFormatter.string(for: measure.metricValue($0), style: .row) }
        }
    }

    /// The kinds of token that have any, largest first.
    var tokenParts: [TokenPart] {
        UsageMeasure.tokenParts
            .compactMap { part in totals[part.measure].map { TokenPart(title: part.title, number: $0) } }
            .filter { $0.number > 0 }
            .sorted { $0.number > $1.number }
    }

    /// Some providers count cached tokens inside input, so only parts that add up to the total can be
    /// drawn as shares of it.
    var tokenPartsFillTotal: Bool {
        guard let total = totals[.tokens], total > 0 else { return false }
        return abs(tokenParts.reduce(0) { $0 + $1.number } - total) < 1
    }
}

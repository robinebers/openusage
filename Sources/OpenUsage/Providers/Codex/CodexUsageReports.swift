import Foundation

/// ChatGPT's daily usage reports, parsed into days keyed by their UTC `yyyy-MM-dd` date. A report with any
/// malformed day is rejected whole, so a day is never partly read.
enum CodexUsageReports {
    struct Report: Equatable {
        var days: [String: UsageDay]
        /// What a date the report leaves out stands for.
        var quietDay: UsageDay
    }

    /// A credits report without charged credits, which reports none for any day.
    private static let noCredits = Report(days: [:], quietDay: UsageDay(totals: UsageTotals()))

    /// `analytics/daily-workspace-usage-counts`: each day's turns, and its text tokens when reported. A date
    /// it leaves out is not reported yet, so it has neither.
    static func counts(_ body: Data) -> Report? {
        guard let records = records(body) else { return nil }
        var days: [String: UsageDay] = [:]
        for record in records {
            guard let date = date(record), let totals = record["totals"] as? [String: Any],
                  let turns = count(totals["turns"])
            else { return nil }
            var values: [UsageMeasure: Double] = [.turns: turns]
            switch totals["text_total_tokens"] {
            case nil, is NSNull: break
            case let tokens:
                guard let tokens = count(tokens) else { return nil }
                values[.tokens] = tokens
            }
            add(UsageDay(totals: UsageTotals(values: values)), on: date, to: &days)
        }
        return Report(days: days, quietDay: UsageDay(totals: UsageTotals()))
    }

    /// `usage/credit-usage-events`: the credits charged, summed per day. A refund can be negative.
    static func creditEvents(_ body: Data) -> Report? {
        guard let records = records(body) else { return nil }
        var days: [String: UsageDay] = [:]
        for record in records {
            guard let date = date(record), let amount = ProviderParse.number(record["credit_amount"]) else { return nil }
            add(UsageDay(totals: UsageTotals(values: [.credits: amount])), on: date, to: &days)
        }
        return Report(days: days, quietDay: UsageDay(totals: .zero([.credits])))
    }

    /// `usage/daily-workspace-user-token-usage-breakdown`: each day's charged credits
    /// (`premium_usage_values.credit_usage_credits`) and each model's (`on_demand_credits`).
    static func workspaceCredits(_ body: Data) -> Report? {
        guard let records = records(body) else { return nil }
        var days: [String: UsageDay] = [:]
        for record in records {
            guard let date = date(record) else { return nil }
            guard let premium = (record["premium_usage_values"] as? [String: Any])?["credit_usage_credits"] as? [String: Any]
            else { return noCredits }
            guard let charged = numbers(premium) else { return nil }
            var models: [String: Double]? = [:]
            for model in record["models"] as? [[String: Any]] ?? [] {
                guard let credits = ProviderParse.number(model["on_demand_credits"]) else {
                    models = nil
                    break
                }
                models?[model["model"] as? String ?? "Unknown", default: 0] += credits
            }
            add(creditDay(charged.values.reduce(0, +), models: models), on: date, to: &days)
        }
        return Report(days: days, quietDay: creditDay(0, models: [:]))
    }

    /// `usage/daily-workspace-user-credit-usage?breakdown=model`: each day's charged credits by model.
    static func enterpriseCredits(_ body: Data) -> Report? {
        guard let records = records(body) else { return nil }
        var days: [String: UsageDay] = [:]
        for record in records {
            guard let date = date(record) else { return nil }
            guard let values = record["values"] as? [String: Any] else { return noCredits }
            guard let models = numbers(values) else { return nil }
            add(creditDay(models.values.reduce(0, +), models: models), on: date, to: &days)
        }
        return Report(days: days, quietDay: creditDay(0, models: [:]))
    }

    /// The day both reports state for `date`: turns and tokens from the counts, credits and models from the other.
    static func day(_ date: String, counts: Report, credits: Report) -> UsageDay {
        let counted = counts.days[date] ?? counts.quietDay
        let charged = credits.days[date] ?? credits.quietDay
        return UsageDay(
            totals: UsageTotals(values: counted.totals.values.merging(charged.totals.values) { _, credits in credits }),
            byModel: charged.byModel
        )
    }

    private static func records(_ body: Data) -> [[String: Any]]? {
        ProviderParse.jsonObject(body)?["data"] as? [[String: Any]]
    }

    private static func date(_ record: [String: Any]) -> String? {
        guard let date = record["date"] as? String, date.count >= 10 else { return nil }
        return String(date.prefix(10))
    }

    private static func creditDay(_ credits: Double, models: [String: Double]?) -> UsageDay {
        UsageDay(totals: UsageTotals(values: [.credits: credits]), byModel: models?.mapValues { UsageTotals(values: [.credits: $0]) })
    }

    /// Several records for one date add up, as the Codex client sums them.
    private static func add(_ day: UsageDay, on date: String, to days: inout [String: UsageDay]) {
        guard let earlier = days[date] else { return days[date] = day }
        let byModel = earlier.byModel.flatMap { earlier in day.byModel.map { earlier.merging($0) { $0.adding($1) } } }
        days[date] = UsageDay(totals: earlier.totals.adding(day.totals), byModel: byModel)
    }

    /// Credit amounts, which can be negative adjustments; nil when any is not a number.
    private static func numbers(_ amounts: [String: Any]) -> [String: Double]? {
        let numbers = amounts.compactMapValues(ProviderParse.number)
        return numbers.count == amounts.count ? numbers : nil
    }

    private static func count(_ value: Any?) -> Double? {
        ProviderParse.number(value).flatMap { $0 >= 0 ? $0 : nil }
    }
}

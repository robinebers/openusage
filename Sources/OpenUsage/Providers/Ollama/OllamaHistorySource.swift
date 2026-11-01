import Foundation

/// Reads Ollama's UTC days in one call: the last 7 days when every due day is among them, else 30.
struct OllamaHistorySource: UsageHistorySource {
    var client: OllamaUsageClient
    var apiKey: String
    var accountID: String

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let measures: [(field: String, measure: UsageMeasure)] = [
        ("request_count", .requests), ("usage_usd", .usageValue), ("input_tokens", .inputTokens),
        ("cached_input_tokens", .cacheReadTokens), ("output_tokens", .outputTokens)
    ]

    var calendar: Calendar { Self.utc }
    /// Hourly, so history adds one call an hour per account.
    var rereadInterval: TimeInterval? { 3600 }

    func read(_ days: [Date], asOf: Date, calendar: Calendar) async -> (days: [Date: UsageDay], rateLimitedFor: TimeInterval?) {
        let tag = LogTag.plugin("ollama")
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: asOf)) ?? .distantFuture
        let response: HTTPResponse
        do {
            response = try await client.fetchUsage(apiKey: apiKey, range: days.allSatisfy { $0 >= weekAgo } ? "7d" : "30d")
        } catch {
            AppLog.warn(tag, "\(accountID) usage history: request failed")
            return ([:], nil)
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(tag, "\(accountID) usage history: HTTP \(response.statusCode)")
            return ([:], nil)
        }
        guard let read = Self.days(response.body, calendar: calendar) else {
            AppLog.warn(tag, "\(accountID) usage history: invalid response")
            return ([:], nil)
        }
        let due = Set(days)
        return (read.filter { due.contains($0.key) }, nil)
    }

    /// Every bucket keyed by its UTC day, or nil when any bucket is not one, so a read is never partly used.
    /// A day is split by model only when no usage falls in Ollama's `remainder` beyond the named models.
    static func days(_ body: Data, calendar: Calendar) -> [Date: UsageDay]? {
        guard let root = ProviderParse.jsonObject(body), root["granularity"] as? String == "day",
              let buckets = root["buckets"] as? [Any]
        else { return nil }
        var days: [Date: UsageDay] = [:]
        for rawBucket in buckets {
            guard let bucket = rawBucket as? [String: Any],
                  let from = (bucket["from"] as? String).flatMap(OpenUsageISO8601.date(from:)),
                  let until = (bucket["until"] as? String).flatMap(OpenUsageISO8601.date(from:)),
                  calendar.startOfDay(for: from) == from, days[from] == nil,
                  let end = calendar.date(byAdding: .day, value: 1, to: from), from < until, until <= end,
                  let totals = totals(bucket)
            else { return nil }
            var byModel: [String: UsageTotals]?
            if let rawGroups = bucket["groups"] {
                guard let groups = rawGroups as? [Any] else { return nil }
                var models: [String: UsageTotals] = [:]
                for rawGroup in groups {
                    guard let group = rawGroup as? [String: Any], let model = (group["model"] as? String)?.nilIfEmpty,
                          models[model] == nil, let modelTotals = Self.totals(group)
                    else { return nil }
                    models[model] = modelTotals
                }
                byModel = bucket["remainder"] == nil ? models : nil
            }
            days[from] = UsageDay(totals: totals, byModel: byModel)
        }
        return days
    }

    /// Cached input is part of input, so tokens are input plus output. Nil without a request count, or
    /// when a figure is not a number of zero or more.
    private static func totals(_ object: [String: Any]) -> UsageTotals? {
        var totals = UsageTotals()
        for (field, measure) in measures {
            guard let raw = object[field], !(raw is NSNull) else { continue }
            guard let number = ProviderParse.number(raw), number >= 0 else { return nil }
            totals.values[measure] = number
        }
        guard totals[.requests] != nil else { return nil }
        if let input = totals[.inputTokens], let output = totals[.outputTokens] {
            totals.values[.tokens] = input + output
        }
        return totals
    }
}

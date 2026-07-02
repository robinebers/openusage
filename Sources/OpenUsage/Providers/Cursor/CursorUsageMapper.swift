import Foundation

struct CursorMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum CursorUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case usageAfterRefreshFailed
    case requestBasedUnavailable(String)
    case totalUsageLimitMissing
    case noActiveSubscription

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        case .usageAfterRefreshFailed:
            return "Usage request failed after refresh. Try again."
        case .requestBasedUnavailable(let message):
            return message
        case .totalUsageLimitMissing:
            return "Total usage limit missing from API response."
        case .noActiveSubscription:
            return "No active Cursor subscription."
        }
    }
}

enum CursorUsageMapper {
    static let billingPeriodMs = MetricPeriod.monthMs

    static func mapUsage(
        usage: [String: Any],
        planName: String?,
        creditGrants: [String: Any]?,
        stripeBalanceCents: Double
    ) throws -> CursorMappedUsage {
        guard usage["enabled"] as? Bool != false,
              let planUsage = usage["planUsage"] as? [String: Any]
        else {
            throw CursorUsageError.noActiveSubscription
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hasPlanUsageLimit = ProviderParse.number(planUsage["limit"]) != nil
        let hasTotalUsagePercent = ProviderParse.number(planUsage["totalPercentUsed"]) != nil

        guard hasPlanUsageLimit || hasTotalUsagePercent else {
            throw CursorUsageError.totalUsageLimitMissing
        }

        var lines: [MetricLine] = []
        appendCredits(creditGrants: creditGrants, stripeBalanceCents: stripeBalanceCents, to: &lines)

        let planUsedCents = ProviderParse.number(planUsage["totalSpend"])
            ?? ((ProviderParse.number(planUsage["limit"]) ?? 0) - (ProviderParse.number(planUsage["remaining"]) ?? 0))
        let computedPercentUsed = ProviderParse.number(planUsage["limit"]).flatMap { limit -> Double? in
            guard limit > 0 else { return nil }
            return planUsedCents / limit * 100
        } ?? 0
        let totalUsagePercent = ProviderParse.number(planUsage["totalPercentUsed"]) ?? computedPercentUsed

        let cycle = billingCycle(from: usage)
        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        let pooledLimit = ProviderParse.number(spendLimitUsage?["pooledLimit"]) ?? 0
        let isTeamAccount = normalizedPlan == "team"
            || (spendLimitUsage?["limitType"] as? String)?.lowercased() == "team"
            || pooledLimit > 0

        if isTeamAccount {
            guard let limitCents = ProviderParse.number(planUsage["limit"]) else {
                throw CursorUsageError.requestBasedUnavailable("Cursor request-based usage data unavailable. Try again later.")
            }
            lines.append(.progress(
                label: "Total usage",
                used: ProviderParse.centsToDollars(planUsedCents),
                limit: ProviderParse.centsToDollars(limitCents),
                format: .dollars,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        } else {
            lines.append(.progress(
                label: "Total usage",
                used: totalUsagePercent,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let autoPercentUsed = ProviderParse.number(planUsage["autoPercentUsed"]) {
            lines.append(.progress(
                label: "Auto usage",
                used: autoPercentUsed,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let apiPercentUsed = ProviderParse.number(planUsage["apiPercentUsed"]) {
            lines.append(.progress(
                label: "API usage",
                used: apiPercentUsed,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let spendLimitUsage {
            let limit = ProviderParse.number(spendLimitUsage["individualLimit"]) ?? ProviderParse.number(spendLimitUsage["pooledLimit"]) ?? 0
            let remaining = ProviderParse.number(spendLimitUsage["individualRemaining"]) ?? ProviderParse.number(spendLimitUsage["pooledRemaining"]) ?? 0
            let spent = onDemandSpendCents(from: spendLimitUsage, limit: limit, remaining: remaining)
            if limit > 0 {
                lines.append(.progress(
                    label: "On-demand",
                    used: ProviderParse.centsToDollars(spent),
                    limit: ProviderParse.centsToDollars(limit),
                    format: .dollars
                ))
            } else if spent > 0 {
                lines.append(.values(
                    label: "On-demand",
                    values: [MetricValue(number: ProviderParse.centsToDollars(spent), kind: .dollars)]
                ))
            }
        }

        return CursorMappedUsage(plan: planLabel(planName), lines: lines)
    }

    private static func onDemandSpendCents(from spendLimitUsage: [String: Any], limit: Double, remaining: Double) -> Double {
        let reported = [
            ProviderParse.number(spendLimitUsage["individualUsed"]),
            ProviderParse.number(spendLimitUsage["pooledUsed"]),
            ProviderParse.number(spendLimitUsage["totalSpend"])
        ].compactMap { $0 }
        if let positive = reported.first(where: { $0 > 0 }) {
            return positive
        }
        let inferred = max(0, limit - remaining)
        return inferred > 0 ? inferred : (reported.first ?? 0)
    }

    static func mapRequestBasedUsage(
        _ usage: [String: Any]?,
        planName: String?,
        unavailableMessage: String
    ) throws -> CursorMappedUsage {
        var lines: [MetricLine] = []
        if let gpt4 = usage?["gpt-4"] as? [String: Any],
           let limit = ProviderParse.number(gpt4["maxRequestUsage"]),
           limit > 0 {
            let used = ProviderParse.number(gpt4["numRequests"]) ?? 0
            let cycleStart = (usage?["startOfMonth"] as? String).flatMap(OpenUsageISO8601.date(from:))
            lines.append(.progress(
                label: "Requests",
                used: used,
                limit: limit,
                format: .count(suffix: "requests"),
                resetsAt: cycleStart?.addingTimeInterval(TimeInterval(billingPeriodMs) / 1000),
                periodDurationMs: billingPeriodMs
            ))
        }

        guard !lines.isEmpty else {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }

        return CursorMappedUsage(plan: planLabel(planName), lines: lines)
    }

    static func mapUsageSummary(
        _ summary: [String: Any],
        planName: String?,
        creditGrants: [String: Any]?,
        stripeBalanceCents: Double
    ) throws -> CursorMappedUsage {
        var lines: [MetricLine] = []
        appendCredits(creditGrants: creditGrants, stripeBalanceCents: stripeBalanceCents, to: &lines)

        let cycle = billingCycleFromSummary(summary)
        let teamUsage = summary["teamUsage"] as? [String: Any]
        let individualUsage = summary["individualUsage"] as? [String: Any]
        let pooled = teamUsage?["pooled"] as? [String: Any]
        let onDemand = teamUsage?["onDemand"] as? [String: Any]
        let overall = individualUsage?["overall"] as? [String: Any]

        let hasIndividualOverall = appendDollarUsageBucket(
            overall,
            label: "Total usage",
            resetsAt: cycle.resetsAt,
            periodDurationMs: cycle.periodDurationMs,
            to: &lines
        )
        var hasUsageMetric = hasIndividualOverall
        if !hasUsageMetric {
            hasUsageMetric = appendDollarUsageBucket(
                pooled,
                label: "Total usage",
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs,
                to: &lines
            )
        } else if appendDollarUsageBucket(
            pooled,
            label: "Team pool",
            resetsAt: cycle.resetsAt,
            periodDurationMs: cycle.periodDurationMs,
            to: &lines
        ) {
            hasUsageMetric = true
        }

        if let autoPercent = percentFromDisplayMessage(summary["autoModelSelectedDisplayMessage"] as? String) {
            hasUsageMetric = true
            lines.append(.progress(
                label: "Auto usage",
                used: autoPercent,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let apiPercent = percentFromDisplayMessage(summary["namedModelSelectedDisplayMessage"] as? String) {
            hasUsageMetric = true
            lines.append(.progress(
                label: "API usage",
                used: apiPercent,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if appendDollarUsageBucket(onDemand, label: "On-demand", to: &lines) {
            hasUsageMetric = true
        }

        guard hasUsageMetric else {
            throw CursorUsageError.requestBasedUnavailable("Enterprise usage data unavailable. Try again later.")
        }

        let resolvedPlan = planName ?? (summary["membershipType"] as? String)
        return CursorMappedUsage(plan: planLabel(resolvedPlan), lines: lines)
    }

    static func shouldUseUsageSummaryFallback(usage: [String: Any], planName: String?) -> Bool {
        let (shouldFallback, _) = shouldUseRequestBasedFallback(
            usage: usage,
            planName: planName,
            planInfoUnavailable: false
        )
        guard shouldFallback else { return false }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalizedPlan == "enterprise" || normalizedPlan == "team" {
            return true
        }

        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        let pooledLimit = ProviderParse.number(spendLimitUsage?["pooledLimit"]) ?? 0
        return (spendLimitUsage?["limitType"] as? String)?.lowercased() == "team" || pooledLimit > 0
    }

    private static func appendDollarUsageBucket(
        _ bucket: [String: Any]?,
        label: String,
        resetsAt: Date? = nil,
        periodDurationMs: Int? = nil,
        to lines: inout [MetricLine]
    ) -> Bool {
        guard bucket?["enabled"] as? Bool != false,
              let limitCents = ProviderParse.number(bucket?["limit"]),
              limitCents > 0
        else {
            return false
        }
        let usedCents = ProviderParse.number(bucket?["used"])
            ?? (limitCents - (ProviderParse.number(bucket?["remaining"]) ?? 0))
        lines.append(.progress(
            label: label,
            used: ProviderParse.centsToDollars(usedCents),
            limit: ProviderParse.centsToDollars(limitCents),
            format: .dollars,
            resetsAt: resetsAt,
            periodDurationMs: periodDurationMs
        ))
        return true
    }

    private static func billingCycleFromSummary(_ summary: [String: Any]) -> (resetsAt: Date?, periodDurationMs: Int) {
        let cycleStart = (summary["billingCycleStart"] as? String).flatMap(OpenUsageISO8601.date(from:))
        let cycleEnd = (summary["billingCycleEnd"] as? String).flatMap(OpenUsageISO8601.date(from:))
        guard let cycleStart, let cycleEnd, cycleEnd > cycleStart else {
            return (cycleEnd, billingPeriodMs)
        }
        return (
            cycleEnd,
            Int(cycleEnd.timeIntervalSince(cycleStart) * 1000)
        )
    }

    private static func percentFromDisplayMessage(_ message: String?) -> Double? {
        guard let message else { return nil }
        let pattern = #"(\d+(?:\.\d+)?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message)
        else {
            return nil
        }
        return Double(message[range])
    }

    static func shouldUseRequestBasedFallback(
        usage: [String: Any],
        planName: String?,
        planInfoUnavailable: Bool
    ) -> (shouldFallback: Bool, message: String) {
        guard usage["enabled"] as? Bool != false else {
            return (false, "")
        }

        let planUsage = usage["planUsage"] as? [String: Any]
        let hasPlanUsage = planUsage != nil
        let hasPlanUsageLimit = planUsage.flatMap { ProviderParse.number($0["limit"]) } != nil
        let planUsageLimitMissing = hasPlanUsage && !hasPlanUsageLimit
        let hasTotalUsagePercent = planUsage.flatMap { ProviderParse.number($0["totalPercentUsed"]) } != nil
        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let planUsageUnusable = !hasPlanUsage || planUsageLimitMissing

        if planUsageUnusable && normalizedPlan == "enterprise" {
            return (true, "Enterprise usage data unavailable. Try again later.")
        }
        if planUsageUnusable && normalizedPlan == "team" {
            return (true, "Team request-based usage data unavailable. Try again later.")
        }
        if planUsageUnusable && !hasTotalUsagePercent && normalizedPlan.isEmpty && planInfoUnavailable {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        let pooledLimit = ProviderParse.number(spendLimitUsage?["pooledLimit"]) ?? 0
        let teamInferred = (spendLimitUsage?["limitType"] as? String)?.lowercased() == "team" || pooledLimit > 0
        if teamInferred && planUsageLimitMissing {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        return (false, "")
    }

    /// Append the shared Today / Yesterday / Last 30 Days spend tiles from Cursor's CSV rows. The rows
    /// are aggregated into one local-calendar-day `DailyUsageSeries` and handed to `SpendTileMapper`
    /// — the same builder the Claude/Codex/Grok tiles use — so the output is identical apart from the
    /// `estimated: false` flag (Cursor spend is server-priced, so its dollars are not marked estimated). Callers only
    /// invoke this when the CSV fetched and parsed, so a failure appends nothing and the tiles read
    /// "No data".
    static func appendSpendLines(rows: [CursorUsageCSVRow], now: Date, to lines: inout [MetricLine]) {
        let calendar = Calendar.current
        var costByDay: [String: Double] = [:]
        var tokensByDay: [String: Int] = [:]
        // Models no pricing source can price (nil imputed cost) contribute tokens but $0 of cost, so a
        // period that used one has an understated dollar figure. Track those names per day so the spend
        // tile can warn which model made its cost incomplete. Only rows that actually spent tokens count —
        // a 0-token row of an unknown model changes nothing, so it isn't worth flagging.
        var unknownModelsByDay: [String: Set<String>] = [:]
        for row in rows {
            let day = dayKey(from: row.date, calendar: calendar)
            costByDay[day, default: 0] += row.imputedCostDollars ?? 0
            tokensByDay[day, default: 0] += row.tokens.totalTokens
            let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if row.tokens.totalTokens > 0, !model.isEmpty, row.imputedCostDollars == nil {
                unknownModelsByDay[day, default: []].insert(model)
            }
        }

        // Sum raw dollars per day, then snap to whole cents once — rounding per row would accumulate
        // sub-cent drift across a busy day.
        let daily = tokensByDay.keys.sorted(by: >).map { day in
            DailyUsageEntry(
                date: day,
                totalTokens: tokensByDay[day] ?? 0,
                costUSD: ((costByDay[day] ?? 0) * 100).rounded() / 100
            )
        }
        let series = DailyUsageSeries(daily: daily)
        SpendTileMapper.appendTokenUsage(series, to: &lines, now: now, estimated: false,
                                         unknownModelsByDay: unknownModelsByDay)
        // Cursor's tokens come from the server-priced usage CSV, not a local CLI log, so the trend
        // note names that source rather than the "estimated from local logs" line the log-scanning
        // providers use. Tokens are measured either way.
        SpendTileMapper.appendUsageTrend(series, to: &lines, now: now, note: "From your Cursor usage history")
    }

    private static func dayKey(from date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func stripeBalanceCents(from response: HTTPResponse?) -> Double {
        guard let response,
              (200..<300).contains(response.statusCode),
              let stripe = ProviderParse.jsonObject(response.body),
              let balance = ProviderParse.number(stripe["customerBalance"]),
              balance < 0
        else {
            return 0
        }
        return abs(balance)
    }

    private static func appendCredits(creditGrants: [String: Any]?, stripeBalanceCents: Double, to lines: inout [MetricLine]) {
        let hasCreditGrants = creditGrants?["hasCreditGrants"] as? Bool == true
        let grantTotalCents = hasCreditGrants ? ProviderParse.number(creditGrants?["totalCents"]) ?? 0 : 0
        let grantUsedCents = hasCreditGrants ? ProviderParse.number(creditGrants?["usedCents"]) ?? 0 : 0
        let hasValidGrantData = hasCreditGrants && grantTotalCents > 0
        let combinedTotalCents = (hasValidGrantData ? grantTotalCents : 0) + stripeBalanceCents
        let remainingCents = max(0, combinedTotalCents - (hasValidGrantData ? grantUsedCents : 0))

        guard combinedTotalCents > 0 else { return }
        lines.append(.values(
            label: "Credits",
            values: [MetricValue(number: ProviderParse.centsToDollars(remainingCents), kind: .dollars)]
        ))
    }

    private static func billingCycle(from usage: [String: Any]) -> (resetsAt: Date?, periodDurationMs: Int) {
        let cycleStart = ProviderParse.number(usage["billingCycleStart"])
        let cycleEnd = ProviderParse.number(usage["billingCycleEnd"])
        guard let cycleStart,
              let cycleEnd,
              cycleEnd > cycleStart
        else {
            return (cycleEnd.map { Date(timeIntervalSince1970: $0 / 1000) }, billingPeriodMs)
        }
        return (
            Date(timeIntervalSince1970: cycleEnd / 1000),
            Int(cycleEnd - cycleStart)
        )
    }

    private static func planLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.titleCased(separator: \.isWhitespace)
    }
}

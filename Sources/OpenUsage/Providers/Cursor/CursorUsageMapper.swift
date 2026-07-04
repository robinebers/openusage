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
    ///
    /// Model breakdown rows group by base model, not raw CSV slug: Cursor exports one slug per thinking
    /// effort / fast combination (`claude-opus-4-8-thinking-max`, `gpt-5.5-extra-high-fast`, …), and a
    /// panel of near-duplicate rows hides the actual ranking. The supplement's alias rules already
    /// collapse those slugs to a canonical pricing key, and `-fast` canonicals fold into their base, so
    /// the family comes from the same machinery that prices the row (ported from cursorcat's
    /// family grouping). The raw slugs survive as `variants` — the per-effort breakdown the row's
    /// tooltip shows.
    static func appendSpendLines(rows: [CursorUsageCSVRow], now: Date, pricing: ModelPricing, to lines: inout [MetricLine]) {
        let calendar = Calendar.current
        var costByDay: [String: Double] = [:]
        var tokensByDay: [String: Int] = [:]
        var modelsByDay: [String: [String: ModelAccumulator]] = [:]
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
            let modelName = model.isEmpty ? ModelUsageEntry.unattributedModelName : model
            let family = model.isEmpty ? modelName : familyName(for: model, pricing: pricing)
            modelsByDay[day, default: [:]][family, default: ModelAccumulator()].add(
                variant: modelName,
                tokens: row.tokens.totalTokens,
                costUSD: row.imputedCostDollars
            )
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
        let modelUsage = ModelUsageSeries(daily: modelsByDay.keys.sorted(by: >).map { day in
            DailyModelUsageEntry(
                date: day,
                models: modelsByDay[day, default: [:]].map { model, accumulator in
                    accumulator.entry(model: model)
                }
            )
        })
        SpendTileMapper.appendTokenUsage(series, to: &lines, now: now, estimated: false,
                                         unknownModelsByDay: unknownModelsByDay,
                                         modelUsage: modelUsage,
                                         modelSourceNote: "From your Cursor usage export")
        // Cursor's tokens come from the server-priced usage CSV, not a local CLI log, so the trend
        // note names that source rather than the "estimated from local logs" line the log-scanning
        // providers use. Tokens are measured either way.
        SpendTileMapper.appendUsageTrend(series, to: &lines, now: now, note: "From your Cursor usage history")
    }

    private static func dayKey(from date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// The display family for a raw CSV slug: its canonical pricing key with a `-fast` suffix folded
    /// into the base (`gpt-5.5-extra-high-fast` → `gpt-5.5-fast` → `gpt-5.5`). Slugs no alias rule
    /// knows keep their raw name — a wrong guess would silently merge unrelated models.
    private static func familyName(for model: String, pricing: ModelPricing) -> String {
        let canonical = pricing.supplement.canonicalName(for: model) ?? model
        guard canonical.hasSuffix("-fast") else { return canonical }
        let base = String(canonical.dropLast("-fast".count))
        return base.isEmpty ? canonical : base
    }

    private struct ModelAccumulator {
        var tokens = 0
        var costUSD: Double?
        var variants: [String: (tokens: Int, costUSD: Double?)] = [:]

        mutating func add(variant: String, tokens: Int, costUSD: Double?) {
            self.tokens += tokens
            if let costUSD {
                self.costUSD = (self.costUSD ?? 0) + costUSD
            }
            let existing = variants[variant] ?? (0, nil)
            let combinedCost: Double? = costUSD.map { (existing.costUSD ?? 0) + $0 } ?? existing.costUSD
            variants[variant] = (existing.tokens + tokens, combinedCost)
        }

        func entry(model: String) -> ModelUsageEntry {
            // A single variant with the family's own name is not a breakdown — leave `variants` nil so
            // the hover tooltip falls back to plain figures.
            let list = variants.map { ModelUsageVariant(model: $0.key, totalTokens: $0.value.tokens, costUSD: $0.value.costUSD) }
            let isTrivial = list.count == 1 && list[0].model == model
            return ModelUsageEntry(model: model, totalTokens: tokens, costUSD: costUSD,
                                   variants: isTrivial ? nil : list)
        }
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

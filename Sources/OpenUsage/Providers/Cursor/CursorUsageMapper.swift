import Foundation

struct CursorMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// The handful of facts the three plan-usage decisions read off Cursor's untyped `usage` payload —
/// the map guards, the request-based fallback, and the generic fallback. Decoded once here so those
/// predicates can't drift apart (they steer one flow and previously spelled the same checks out
/// independently across two files).
struct CursorPlanUsageFacts {
    /// `usage.enabled` is only "off" when explicitly `false`; absent reads as enabled.
    let isEnabled: Bool
    /// A `planUsage` object is present at all.
    let hasPlanUsage: Bool
    /// `planUsage.limit`, when numeric.
    let limit: Double?
    /// `planUsage.totalPercentUsed`, when numeric.
    let totalPercentUsed: Double?
    /// `spendLimitUsage.limitType`, lowercased.
    let spendLimitType: String?
    /// `spendLimitUsage.pooledLimit` (0 when absent).
    let pooledLimit: Double

    init(usage: [String: Any]) {
        isEnabled = usage["enabled"] as? Bool != false
        let planUsage = usage["planUsage"] as? [String: Any]
        hasPlanUsage = planUsage != nil
        limit = planUsage.flatMap { ProviderParse.number($0["limit"]) }
        totalPercentUsed = planUsage.flatMap { ProviderParse.number($0["totalPercentUsed"]) }
        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        spendLimitType = (spendLimitUsage?["limitType"] as? String)?.lowercased()
        pooledLimit = ProviderParse.number(spendLimitUsage?["pooledLimit"]) ?? 0
    }

    var hasLimit: Bool { limit != nil }
    var hasTotalUsagePercent: Bool { totalPercentUsed != nil }
    /// `planUsage` exists but carries no usable limit — the "present but unusable" state the fallbacks key on.
    var planUsageLimitMissing: Bool { hasPlanUsage && !hasLimit }
    var planUsageUnusable: Bool { !hasPlanUsage || planUsageLimitMissing }
    /// Team account inferred from the spend-limit shape alone (independent of the plan name).
    var isTeamByShape: Bool { spendLimitType == "team" || pooledLimit > 0 }
    /// The generic request-based fallback trigger: an enabled account with a `planUsage` that carries
    /// neither a limit nor a total-percent figure.
    var shouldTryGenericRequestFallback: Bool {
        isEnabled && hasPlanUsage && !hasLimit && !hasTotalUsagePercent
    }
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
        let facts = CursorPlanUsageFacts(usage: usage)
        guard facts.isEnabled,
              let planUsage = usage["planUsage"] as? [String: Any]
        else {
            throw CursorUsageError.noActiveSubscription
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        guard facts.hasLimit || facts.hasTotalUsagePercent else {
            throw CursorUsageError.totalUsageLimitMissing
        }

        var lines: [MetricLine] = []
        appendCredits(creditGrants: creditGrants, stripeBalanceCents: stripeBalanceCents, to: &lines)

        let planUsedCents = ProviderParse.number(planUsage["totalSpend"])
            ?? ((facts.limit ?? 0) - (ProviderParse.number(planUsage["remaining"]) ?? 0))
        let computedPercentUsed = facts.limit.flatMap { limit -> Double? in
            guard limit > 0 else { return nil }
            return planUsedCents / limit * 100
        } ?? 0
        let totalUsagePercent = facts.totalPercentUsed ?? computedPercentUsed

        let cycle = billingCycle(from: usage)
        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        let isTeamAccount = normalizedPlan == "team" || facts.isTeamByShape

        if isTeamAccount {
            guard let limitCents = facts.limit else {
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
        let facts = CursorPlanUsageFacts(usage: usage)
        guard facts.isEnabled else {
            return (false, "")
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        if facts.planUsageUnusable && normalizedPlan == "enterprise" {
            return (true, "Enterprise usage data unavailable. Try again later.")
        }
        if facts.planUsageUnusable && normalizedPlan == "team" {
            return (true, "Team request-based usage data unavailable. Try again later.")
        }
        if facts.planUsageUnusable && !facts.hasTotalUsagePercent && normalizedPlan.isEmpty && planInfoUnavailable {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        if facts.isTeamByShape && facts.planUsageLimitMissing {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        return (false, "")
    }

    /// Append the shared Today / Yesterday / Last 30 Days spend tiles from Cursor's CSV rows. The rows
    /// are aggregated into one local-calendar-day `DailyUsageSeries` and handed to `SpendTileMapper`
    /// — the same builder the Claude/Codex/Grok tiles use — so the output is identical apart from the
    /// source note. Cursor's costs are calculated locally from the exported token counts, so the dollar
    /// values carry the estimate icon. Callers only invoke this when the CSV fetched and parsed, so a
    /// failure appends nothing and the tiles read "No data".
    ///
    /// Model breakdown rows group by base model, not raw CSV slug: Cursor exports one slug per thinking
    /// effort / fast combination (`claude-opus-4-8-thinking-max`, `gpt-5.5-extra-high-fast`, …), and a
    /// panel of near-duplicate rows hides the actual ranking. The supplement's alias rules already
    /// collapse those slugs to a canonical pricing key, and `-fast` canonicals fold into their base, so
    /// the family comes from the same machinery that prices the row (ported from cursorcat's
    /// family grouping). The raw slugs survive as `variants` — the per-effort breakdown the row's
    /// tooltip shows.
    static func appendSpendLines(
        rows: [CursorUsageCSVRow],
        now: Date,
        pricing: ModelPricing,
        to lines: inout [MetricLine]
    ) -> ProviderUsageHistory {
        let calendar = Calendar.current
        var costByDay: [String: Double] = [:]
        var tokensByDay: [String: Int] = [:]
        var modelsByDay: [String: [String: ModelAccumulator]] = [:]
        // Rows no pricing source can price (nil imputed cost) are excluded from every displayed total —
        // tokens, dollars, the trend, and the model breakdown — because mixing measured tokens with
        // unpriceable ones makes the figures incoherent (a huge token count next to a dollar figure that
        // ignores it). Their model names surface only through the warning triangle: track them per day so
        // the spend tile can warn that its figures are incomplete. Only rows that actually spent tokens
        // count — a 0-token row of an unknown model changes nothing, so it isn't worth flagging.
        var unknownModelsByDay: [String: Set<String>] = [:]
        for row in rows {
            let day = DailyUsageAccumulator.dayKey(from: row.date, calendar: calendar)
            let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let cost = row.imputedCostDollars else {
                if row.tokens.totalTokens > 0, !model.isEmpty {
                    unknownModelsByDay[day, default: []].insert(model)
                }
                continue
            }
            costByDay[day, default: 0] += cost
            tokensByDay[day, default: 0] += row.tokens.totalTokens
            let modelName = model.isEmpty ? ModelUsageEntry.unattributedModelName : model
            let family = model.isEmpty ? modelName : familyName(for: model, pricing: pricing)
            modelsByDay[day, default: [:]][family, default: ModelAccumulator()].add(
                variant: modelName,
                tokens: row.tokens.totalTokens,
                costUSD: cost
            )
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
        SpendTileMapper.appendTokenUsage(series, to: &lines, now: now, estimated: true,
                                         unknownModelsByDay: unknownModelsByDay,
                                         modelUsage: modelUsage,
                                         modelSourceNote: "From your Cursor usage export")
        // Cursor's tokens come from the server-exported usage CSV, not a local CLI log, so the trend
        // note names that source rather than the "estimated from local logs" line the log-scanning
        // providers use. Tokens are measured either way.
        SpendTileMapper.appendUsageTrend(series, to: &lines, now: now, note: "From your Cursor usage export")
        return ProviderUsageHistory(
            series: series,
            modelUsage: modelUsage,
            unknownModelsByDay: unknownModelsByDay
        )
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

    static func stripeBalanceCents(from body: [String: Any]?) -> Double {
        guard let body,
              let balance = ProviderParse.number(body["customerBalance"]),
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

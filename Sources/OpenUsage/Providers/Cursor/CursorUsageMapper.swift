import Foundation

struct CursorPlanUsageFacts {
    let isEnabled: Bool
    let hasPlanUsage: Bool
    let limit: Double?
    let totalPercentUsed: Double?
    let hasModelPools: Bool
    let spendLimitType: String?
    let pooledLimit: Double

    init(usage: [String: Any]) {
        isEnabled = usage["enabled"] as? Bool != false
        let planUsage = usage["planUsage"] as? [String: Any]
        hasPlanUsage = planUsage != nil
        limit = planUsage.flatMap { ProviderParse.number($0["limit"]) }
        totalPercentUsed = planUsage.flatMap { ProviderParse.number($0["totalPercentUsed"]) }
        let auto = planUsage.flatMap { ProviderParse.number($0["autoPercentUsed"]) }
        let api = planUsage.flatMap { ProviderParse.number($0["apiPercentUsed"]) }
        let spent = planUsage.flatMap { ProviderParse.number($0["totalSpend"]) }
            ?? ((limit ?? 0) - (planUsage.flatMap { ProviderParse.number($0["remaining"]) } ?? limit ?? 0))
        if let auto, let api, auto.isFinite, api.isFinite, auto >= 0, api >= 0 {
            hasModelPools = auto > 0 || api > 0 || spent == 0
        } else {
            hasModelPools = false
        }
        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        spendLimitType = (spendLimitUsage?["limitType"] as? String)?.lowercased()
        pooledLimit = ProviderParse.number(spendLimitUsage?["pooledLimit"]) ?? 0
    }

    var hasLimit: Bool { limit != nil }
    var hasTotalUsagePercent: Bool { totalPercentUsed != nil }
    var planUsageLimitMissing: Bool { hasPlanUsage && !hasLimit }
    var planUsageUnusable: Bool { !hasPlanUsage || (planUsageLimitMissing && !hasModelPools) }
    var isTeamByShape: Bool { spendLimitType == "team" || pooledLimit > 0 }
    var shouldTryGenericRequestFallback: Bool {
        isEnabled && hasPlanUsage && !hasLimit && !hasTotalUsagePercent && !hasModelPools
    }
}

enum CursorUsageMapper {
    static let billingPeriodMs = MetricPeriod.monthMs

    /// Grok Bot is Cursor's "Sand" product, with its own weekly allowance and reset window. Pooled
    /// enterprise accounts and accounts without an included allowance have no separate personal meter.
    static func mapGrokBotUsage(_ usage: [String: Any]) -> MetricLine? {
        guard usage["usesPooledEnterpriseAllowance"] as? Bool != true,
              usage["hasNonZeroIncludedLimit"] as? Bool != false,
              usage["includedLimitZero"] as? Bool != true,
              let percent = ProviderParse.number(usage["usagePercent"]),
              percent >= 0
        else {
            return nil
        }

        let reset = (usage["nextResetTimestampUtc"] as? String).flatMap(OpenUsageISO8601.date(from:))
        let start = (usage["currentPeriodStart"] as? String).flatMap(OpenUsageISO8601.date(from:))
        let periodDurationMs: Int
        if let start, let reset, reset > start {
            periodDurationMs = Int(reset.timeIntervalSince(start) * 1000)
        } else {
            periodDurationMs = MetricPeriod.weekMs
        }

        return .percent("Grok Bot usage", ProviderParse.clampPercent(percent), resetsAt: reset, periodMs: periodDurationMs)
    }

    static func mapUsage(
        usage: [String: Any],
        planName: String?,
        creditGrants: [String: Any]?,
        stripeBalanceCents: Double
    ) throws -> ProviderUsage {
        let facts = CursorPlanUsageFacts(usage: usage)
        guard facts.isEnabled,
              let planUsage = usage["planUsage"] as? [String: Any]
        else {
            throw ProviderError.unavailable("No active Cursor subscription.")
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        guard facts.hasLimit || facts.hasTotalUsagePercent || facts.hasModelPools else {
            throw ProviderError.unavailable("Total usage limit missing from API response.")
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

        if isTeamAccount && facts.hasModelPools {
            // Modern Teams seats still report the old $20 allowance. Structured pool data wins;
            // never synthesize a total from stale dollars when Cursor omits totalPercentUsed.
            if let percent = facts.totalPercentUsed {
                lines.append(.percent("Total usage", percent, resetsAt: cycle.resetsAt, periodMs: cycle.periodDurationMs))
            }
        } else if isTeamAccount {
            if let limitCents = facts.limit {
                lines.append(.progress(
                    label: "Total usage",
                    used: ProviderParse.centsToDollars(planUsedCents),
                    limit: ProviderParse.centsToDollars(limitCents),
                    format: .dollars,
                    resetsAt: cycle.resetsAt,
                    periodDurationMs: cycle.periodDurationMs
                ))
            } else if let percent = facts.totalPercentUsed {
                lines.append(.percent("Total usage", percent, resetsAt: cycle.resetsAt, periodMs: cycle.periodDurationMs))
            } else {
                throw ProviderError.unavailable("Cursor request-based usage data unavailable. Try again later.")
            }
        } else {
            lines.append(.percent("Total usage", totalUsagePercent, resetsAt: cycle.resetsAt, periodMs: cycle.periodDurationMs))
        }

        if let autoPercentUsed = ProviderParse.number(planUsage["autoPercentUsed"]) {
            lines.append(.percent("Cursor Models", autoPercentUsed, resetsAt: cycle.resetsAt, periodMs: cycle.periodDurationMs))
        }

        if let apiPercentUsed = ProviderParse.number(planUsage["apiPercentUsed"]) {
            lines.append(.percent("Other Models", apiPercentUsed, resetsAt: cycle.resetsAt, periodMs: cycle.periodDurationMs))
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

        return ProviderUsage(plan: planLabel(planName), lines: lines)
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

    static func shouldUseRequestBasedFallback(
        facts: CursorPlanUsageFacts,
        planName: String?
    ) -> (shouldFallback: Bool, message: String) {
        guard facts.isEnabled else {
            return (false, "")
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        if facts.planUsageUnusable && !facts.hasTotalUsagePercent && normalizedPlan == "enterprise" {
            return (true, "Enterprise usage data unavailable. Try again later.")
        }
        if facts.planUsageUnusable && !facts.hasTotalUsagePercent && normalizedPlan == "team" {
            return (true, "Team request-based usage data unavailable. Try again later.")
        }
        if facts.planUsageUnusable && !facts.hasTotalUsagePercent && normalizedPlan.isEmpty && planName == nil {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        if facts.isTeamByShape && facts.planUsageLimitMissing && !facts.hasModelPools {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        return (false, "")
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
              cycleEnd > cycleStart,
              let periodMs = ProviderParse.int(cycleEnd - cycleStart)
        else {
            return (cycleEnd.map { Date(timeIntervalSince1970: $0 / 1000) }, billingPeriodMs)
        }
        return (Date(timeIntervalSince1970: cycleEnd / 1000), periodMs)
    }

    static let orgMembershipTypes: Set<String> = ["enterprise", "team"]

    static func membershipType(in summary: [String: Any]?) -> String? {
        normalizedMembership(summary?["membershipType"] as? String)
    }

    /// Badge / display plan. Prefer org billing membership over GetPlanInfo when it still says Pro.
    static func resolvedPlanName(planInfoName: String?, membershipType: String?) -> String? {
        let membership = normalizedMembership(membershipType)
        let planInfo = planInfoName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        if let membership, orgMembershipTypes.contains(membership),
           planInfo == nil || ["pro", "pro plan"].contains(planInfo?.lowercased() ?? "") {
            return membership
        }
        return planInfo ?? membership
    }

    static func resolvedPlanLabel(planInfoName: String?, membershipType: String?) -> String? {
        planLabel(resolvedPlanName(planInfoName: planInfoName, membershipType: membershipType))
    }

    private static func normalizedMembership(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    private static func planLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.titleCased(separator: \.isWhitespace)
    }
}

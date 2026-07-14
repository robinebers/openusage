import Foundation

struct FactoryMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum FactoryUsageMapper {
    static func mapUsageResponse(usage: [String: Any]) throws -> FactoryMappedUsage {
        var lines: [MetricLine] = []
        let startDate = ProviderParse.number(usage["startDate"])
        let endDate = ProviderParse.number(usage["endDate"])
        let fallbackResetsAt = dateFromMillis(endDate)
        let fallbackPeriodMs = periodDurationMs(start: startDate, end: endDate)

        addExtraUsageLine(to: &lines, usage: usage)
        addStandardUsageLines(
            to: &lines,
            usage: usage,
            fallbackStart: startDate,
            fallbackEnd: endDate
        )
        addDroidCoreLine(to: &lines, usage: usage)
        addManagedComputersLine(
            to: &lines,
            usage: usage,
            fallbackStart: startDate,
            fallbackEnd: endDate
        )

        if let standard = usage["standard"] as? [String: Any],
           let limit = ProviderParse.number(standard["totalAllowance"]) {
            let used = ProviderParse.number(standard["orgTotalTokensUsed"]) ?? 0
            lines.append(.progress(
                label: "Standard",
                used: used,
                limit: limit,
                format: .count(suffix: "tokens"),
                resetsAt: fallbackResetsAt,
                periodDurationMs: fallbackPeriodMs
            ))
        }

        if let premium = usage["premium"] as? [String: Any],
           let limit = ProviderParse.number(premium["totalAllowance"]),
           limit > 0 {
            let used = ProviderParse.number(premium["orgTotalTokensUsed"]) ?? 0
            lines.append(.progress(
                label: "Premium",
                used: used,
                limit: limit,
                format: .count(suffix: "tokens"),
                resetsAt: fallbackResetsAt,
                periodDurationMs: fallbackPeriodMs
            ))
        }

        guard !lines.isEmpty else {
            throw FactoryUsageError.usageUnavailable
        }

        return FactoryMappedUsage(
            plan: inferPlan(usage: usage, standard: usage["standard"] as? [String: Any]),
            lines: lines
        )
    }

    static func mergeSupplementalUsage(
        usage: [String: Any],
        rootData: [String: Any],
        billingLimits: [String: Any]?,
        computeUsage: [String: Any]?
    ) -> [String: Any] {
        var merged = usage
        let shouldFetchSupplemental = !hasExtendedUsageFields(merged) &&
            (rootData["globalLimit"] != nil || rootData["userLimits"] != nil)

        if shouldFetchSupplemental, let billingLimits {
            let limits = firstObject(
                billingLimits["limits"],
                billingLimits["usageLimits"]
            )
            let standardLimits = limits.flatMap { firstObject($0["standard"], $0["standardUsage"]) }
            if let standardLimits,
               firstObject(merged["standardUsage"], merged["standardLimits"], merged["usageLimits"], merged["limits"]) == nil {
                var standardUsage: [String: Any] = [:]
                if let fiveHour = windowMetric(
                    firstObject(
                        standardLimits["fiveHour"],
                        standardLimits["fiveHourUsage"],
                        standardLimits["five_hour"],
                        standardLimits["5Hour"],
                        standardLimits["5-hour"]
                    ),
                    periodDurationMs: MetricPeriod.sessionMs
                ) {
                    standardUsage["fiveHour"] = fiveHour
                }
                if let weekly = windowMetric(
                    firstObject(standardLimits["weekly"], standardLimits["weeklyUsage"], standardLimits["week"]),
                    periodDurationMs: MetricPeriod.weekMs
                ) {
                    standardUsage["weekly"] = weekly
                }
                if let monthly = windowMetric(
                    firstObject(standardLimits["monthly"], standardLimits["monthlyUsage"], standardLimits["month"]),
                    periodDurationMs: MetricPeriod.monthMs
                ) {
                    standardUsage["monthly"] = monthly
                }
                if !standardUsage.isEmpty {
                    merged["standardUsage"] = standardUsage
                }
            }

            let extraUsageBalanceCents = firstNumber(
                billingLimits,
                keys: ["extraUsageBalanceCents", "extra_usage_balance_cents"]
            )
            if extraUsageBalanceCents != nil,
               firstObject(merged["extraUsage"], merged["extra_usage"], merged["extraUsageBalance"], merged["extra"], merged["overage"]) == nil {
                merged["extraUsage"] = ["remainingCents": extraUsageBalanceCents as Any]
            }

            let coreLimits = limits.flatMap { firstObject($0["core"], $0["droidCore"], $0["droid_core"]) }
            if coreLimits != nil, droidCoreConfig(from: merged) == nil {
                merged["droidCore"] = ["enabled": true]
            }
        }

        if let computeUsage,
           firstObject(
               merged["managedComputers"],
               merged["managedComputerUsage"],
               merged["computers"],
               merged["compute"],
               merged["managedCompute"]
           ) == nil {
            let limitMs = firstNumber(computeUsage, keys: ["limitMs", "includedMs", "allowanceMs", "totalMs", "limit"])
            if let limitMs, limitMs > 0 {
                let usedMs = firstNumber(computeUsage, keys: ["orgUsageMs", "usageMs", "usedMs", "used"]) ?? 0
                merged["managedComputers"] = [
                    "usedHours": usedMs / (60 * 60 * 1000),
                    "includedHours": limitMs / (60 * 60 * 1000),
                    "startDate": firstValue(computeUsage, keys: ["periodStart", "startDate", "startAt"]) as Any,
                    "endDate": firstValue(computeUsage, keys: ["periodEnd", "endDate", "endAt"]) as Any
                ]
            }
        }

        return merged
    }

    private static func addStandardUsageLines(
        to lines: inout [MetricLine],
        usage: [String: Any],
        fallbackStart: Double?,
        fallbackEnd: Double?
    ) {
        let standardUsage = firstObject(
            usage["standardUsage"],
            usage["standardLimits"],
            usage["usageLimits"],
            usage["limits"]
        )
        guard let standardUsage else { return }

        addPercentUsageLine(
            to: &lines,
            label: "5-hour usage",
            metric: firstObject(
                standardUsage["fiveHour"],
                standardUsage["fiveHourUsage"],
                standardUsage["five_hour"],
                standardUsage["5Hour"],
                standardUsage["5-hour"]
            ),
            fallbackStart: fallbackStart,
            fallbackEnd: fallbackEnd,
            defaultPeriodMs: MetricPeriod.sessionMs
        )
        addPercentUsageLine(
            to: &lines,
            label: "Weekly usage",
            metric: firstObject(
                standardUsage["weekly"],
                standardUsage["weeklyUsage"],
                standardUsage["week"]
            ),
            fallbackStart: fallbackStart,
            fallbackEnd: fallbackEnd,
            defaultPeriodMs: MetricPeriod.weekMs
        )
        addPercentUsageLine(
            to: &lines,
            label: "Monthly usage",
            metric: firstObject(
                standardUsage["monthly"],
                standardUsage["monthlyUsage"],
                standardUsage["month"]
            ),
            fallbackStart: fallbackStart,
            fallbackEnd: fallbackEnd,
            defaultPeriodMs: MetricPeriod.monthMs
        )
    }

    private static func addExtraUsageLine(to lines: inout [MetricLine], usage: [String: Any]) {
        let extraUsage = firstObject(
            usage["extraUsage"],
            usage["extra_usage"],
            usage["extraUsageBalance"],
            usage["extra"],
            usage["overage"]
        )
        guard let extraUsage else { return }

        var remaining = firstNumber(extraUsage, keys: [
            "remainingUsd", "remainingUSD", "remainingDollars", "balanceUsd", "balanceUSD", "balance", "amountRemainingUsd"
        ])
        let remainingCents = firstNumber(extraUsage, keys: ["remainingCents", "balanceCents", "amountRemainingCents"])
        if remaining == nil, let remainingCents {
            remaining = ProviderParse.centsToDollars(remainingCents)
        }
        guard let remaining else { return }
        lines.append(.values(label: "Extra Usage", values: [MetricValue(number: remaining, kind: .dollars)]))
    }

    private static func addDroidCoreLine(to lines: inout [MetricLine], usage: [String: Any]) {
        guard isDroidCoreEnabled(usage: usage) else { return }
        lines.append(.badge(label: "Droid Core", text: "Enabled", colorHex: "#f97316"))
    }

    private static func addManagedComputersLine(
        to lines: inout [MetricLine],
        usage: [String: Any],
        fallbackStart: Double?,
        fallbackEnd: Double?
    ) {
        let managed = firstObject(
            usage["managedComputers"],
            usage["managedComputerUsage"],
            usage["computers"],
            usage["compute"],
            usage["managedCompute"]
        )
        guard let managed else { return }

        let used = firstNumber(managed, keys: ["usedHours", "usageHours", "hoursUsed", "used", "current"]) ?? 0
        guard let limit = firstNumber(managed, keys: ["includedHours", "limitHours", "allowanceHours", "totalHours", "limit"]),
              limit > 0 else {
            return
        }

        lines.append(.progress(
            label: "Managed Computers",
            used: used,
            limit: limit,
            format: .count(suffix: "h"),
            resetsAt: metricResetsAt(metric: managed, fallbackEnd: fallbackEnd),
            periodDurationMs: metricPeriodDurationMs(metric: managed, fallbackStart: fallbackStart, fallbackEnd: fallbackEnd)
        ))
    }

    private static func addPercentUsageLine(
        to lines: inout [MetricLine],
        label: String,
        metric: [String: Any]?,
        fallbackStart: Double?,
        fallbackEnd: Double?,
        defaultPeriodMs: Int
    ) {
        guard let metric, let used = percentFromMetric(metric) else { return }
        lines.append(.progress(
            label: label,
            used: (used * 100).rounded() / 100,
            limit: 100,
            format: .percent,
            resetsAt: metricResetsAt(metric: metric, fallbackEnd: fallbackEnd),
            periodDurationMs: metricPeriodDurationMs(
                metric: metric,
                fallbackStart: fallbackStart,
                fallbackEnd: fallbackEnd
            ) ?? defaultPeriodMs
        ))
    }

    private static func inferPlan(usage: [String: Any], standard: [String: Any]?) -> String? {
        let rawPlan = firstString(usage, keys: ["plan", "planName", "tier", "usageMode", "currentUsageMode"])
        var plan = rawPlan.map(planLabel)

        if plan == nil, let allowance = ProviderParse.number(standard?["totalAllowance"]) {
            if allowance >= 200_000_000 {
                plan = "Max"
            } else if allowance >= 20_000_000 {
                plan = "Pro"
            } else if allowance > 0 {
                plan = "Basic"
            }
        }

        if isDroidCoreEnabled(usage: usage) {
            return plan.map { "\($0) + Droid Core" } ?? "Droid Core"
        }
        return plan
    }

    private static func planLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    private static func isDroidCoreEnabled(usage: [String: Any]) -> Bool {
        guard let droidCore = droidCoreConfig(from: usage) else { return false }
        return ProviderParse.bool(droidCore["enabled"]) == true ||
            ProviderParse.bool(droidCore["available"]) == true ||
            ProviderParse.bool(droidCore["included"]) == true
    }

    private static func droidCoreConfig(from usage: [String: Any]) -> [String: Any]? {
        firstObject(
            usage["droidCore"],
            usage["droid_core"],
            (usage["models"] as? [String: Any])?["droidCore"],
            (usage["modelConfiguration"] as? [String: Any])?["droidCore"]
        )
    }

    private static func hasExtendedUsageFields(_ usage: [String: Any]) -> Bool {
        firstObject(
            usage["standardUsage"],
            usage["standardLimits"],
            usage["usageLimits"],
            usage["limits"],
            usage["extraUsage"],
            usage["extra_usage"],
            usage["extraUsageBalance"],
            usage["extra"],
            usage["overage"],
            usage["managedComputers"],
            usage["managedComputerUsage"],
            usage["managedCompute"],
            usage["compute"],
            usage["computers"],
            droidCoreConfig(from: usage)
        ) != nil
    }

    private static func windowMetric(_ metric: [String: Any]?, periodDurationMs: Int) -> [String: Any]? {
        guard let metric else { return nil }
        var out: [String: Any] = [:]
        if let usedPercent = firstNumber(metric, keys: [
            "usedPercent", "percentUsed", "usagePercent", "percentage", "percent"
        ]) {
            out["usedPercent"] = usedPercent
        }
        if let endDate = firstValue(metric, keys: ["windowEnd", "endDate", "endAt", "resetsAt", "resetAt"]) {
            out["endDate"] = endDate
        }
        if out["endDate"] == nil,
           let secondsRemaining = firstNumber(metric, keys: ["secondsRemaining", "remainingSeconds", "secondsLeft"]) {
            out["endDate"] = Date().timeIntervalSince1970 * 1000 + secondsRemaining * 1000
        }
        if periodDurationMs > 0 {
            out["periodDurationMs"] = periodDurationMs
        }
        return out.isEmpty ? nil : out
    }

    private static func percentFromMetric(_ metric: [String: Any]) -> Double? {
        if let ratio = firstValue(metric, keys: ["usedRatio", "usageRatio", "ratio"]) {
            return normalizePercent(ratio, ratioHint: true)
        }
        if let percent = firstValue(metric, keys: [
            "usedPercent", "percentUsed", "usagePercent", "percentage", "percent"
        ]) {
            return normalizePercent(percent, ratioHint: false)
        }
        let used = firstNumber(metric, keys: ["used", "value", "current", "usedAmount"])
        let limit = firstNumber(metric, keys: ["limit", "allowance", "total", "totalAllowance"])
        if let used, let limit, limit > 0 {
            return (used / limit) * 100
        }
        return nil
    }

    private static func normalizePercent(_ value: Any, ratioHint: Bool) -> Double? {
        guard let number = ProviderParse.number(value) else { return nil }
        if ratioHint || (number > 0 && number < 1) {
            return number * 100
        }
        return number
    }

    private static func metricResetsAt(metric: [String: Any], fallbackEnd: Double?) -> Date? {
        if let end = firstValue(metric, keys: ["resetsAt", "resetAt", "endDate", "endAt", "periodEnd", "periodEndDate", "windowEnd"]) {
            return dateFromMillis(ProviderParse.number(end))
        }
        return dateFromMillis(fallbackEnd)
    }

    private static func metricPeriodDurationMs(
        metric: [String: Any],
        fallbackStart: Double?,
        fallbackEnd: Double?
    ) -> Int? {
        if let explicit = firstNumber(metric, keys: ["periodDurationMs", "durationMs", "periodMs"]), explicit > 0 {
            return Int(explicit)
        }
        let start = ProviderParse.number(metricStartValue(metric: metric, fallbackStart: fallbackStart))
        let end = ProviderParse.number(metricEndValue(metric: metric, fallbackEnd: fallbackEnd))
        if let start, let end, end > start {
            return Int(end - start)
        }
        return nil
    }

    private static func metricStartValue(metric: [String: Any], fallbackStart: Double?) -> Any? {
        firstValue(metric, keys: ["startDate", "startAt", "periodStart", "periodStartDate"]) ?? fallbackStart
    }

    private static func metricEndValue(metric: [String: Any], fallbackEnd: Double?) -> Any? {
        firstValue(metric, keys: ["resetsAt", "resetAt", "endDate", "endAt", "periodEnd", "periodEndDate", "windowEnd"]) ?? fallbackEnd
    }

    private static func periodDurationMs(start: Double?, end: Double?) -> Int? {
        guard let start, let end, end > start else { return nil }
        return Int(end - start)
    }

    private static func dateFromMillis(_ value: Double?) -> Date? {
        guard let value else { return nil }
        let seconds = value > 1_000_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func firstObject(_ values: Any?...) -> [String: Any]? {
        for value in values {
            if let object = value as? [String: Any] { return object }
        }
        return nil
    }

    private static func firstNumber(_ source: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = ProviderParse.number(source[key]) { return value }
        }
        return nil
    }

    private static func firstString(_ source: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = (source[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstValue(_ source: [String: Any], keys: [String]) -> Any? {
        for key in keys where source[key] != nil {
            return source[key]
        }
        return nil
    }
}

import Foundation

extension AccountProviderRuntime {
    var widgetDescriptors: [WidgetDescriptor] {
        Self.widgetDescriptors(for: account)
    }

    static func widgetDescriptors(for account: Account) -> [WidgetDescriptor] {
        let provider = provider(for: account)
        return switch account.kind {
        case .claude:
            [
                .percent(key: "session", provider: provider, title: "Session", sessionStartSignal: .missingResetDate)
                    .exportingLimit("session", unit: "percent")
                    .pinnedByDefault(),
                .percent(key: "weekly", provider: provider, title: "Weekly")
                    .exportingLimit("weekly", unit: "percent")
                    .pinnedByDefault(),
                .percent(key: "sonnet", provider: provider, title: "Sonnet")
                    .exportingLimit("sonnet", unit: "percent"),
                .percent(key: "fable", provider: provider, title: "Fable")
                    .exportingLimit("fable", unit: "percent"),
                .boundedDollars(key: "extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage spent",
                                limit: 100, valueWord: "spent")
                    .exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars)),
                rateLimitResets(key: "rateLimitResets", provider: provider)
            ]
        case .codex:
            [
                .percent(key: "session", provider: provider, title: "Session")
                    .exportingLimit("session", unit: "percent")
                    .pinnedByDefault(),
                .percent(key: "weekly", provider: provider, title: "Weekly")
                    .exportingLimit("weekly", unit: "percent")
                    .pinnedByDefault(),
                .percent(key: "spark", provider: provider, title: "Spark")
                    .exportingLimit("spark", unit: "percent"),
                .percent(key: "sparkWeekly", provider: provider, title: "Spark Weekly")
                    .exportingLimit("sparkWeekly", unit: "percent"),
                .values(key: "credits", provider: provider, title: "Extra Usage", metricLabel: "Credits")
                    .exportingLimit("credits", kind: .balance, unit: "credits", source: .value(kind: .count, label: "credits")),
                rateLimitResets(key: "rateLimitResets", provider: provider)
            ]
        case .cursor:
            [
                .percent(key: "usage", provider: provider, title: "Total Usage", metricLabel: "Total usage")
                    .exportingLimit("totalUsage", unit: "percent")
                    .pinnedByDefault(),
                .percent(key: "auto", provider: provider, title: "Cursor Models")
                    .exportingLimit("autoUsage", unit: "percent"),
                .percent(key: "api", provider: provider, title: "Other Models")
                    .exportingLimit("apiUsage", unit: "percent"),
                .boundedDollars(key: "onDemand", provider: provider, title: "Extra Usage", metricLabel: "On-demand",
                                limit: 100, valueWord: "spent")
                    .exportingLimit("onDemand", unit: "usd", source: .progressOrValue(kind: .dollars)),
                .percent(key: "grokBot", provider: provider, title: "Grok Bot", metricLabel: "Grok Bot usage")
                    .exportingLimit("grokBot", unit: "percent"),
                .boundedCount(key: "requests", provider: provider, title: "Requests", limit: 500,
                              periodDurationMs: CursorUsageMapper.billingPeriodMs)
                    .exportingLimit("requests", unit: "requests"),
                .dollarBalance(key: "credits", provider: provider, title: "Credits", valueWord: "left")
                    .exportingLimit("credits", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
                .history(key: "today", provider: provider, .window(.today, .spend, then: .tokens))
                    .pinnedByDefault(),
                .history(key: "yesterday", provider: provider, .window(.yesterday, .spend, then: .tokens)),
                .history(key: "last30", provider: provider, .window(.lastDays(30), .spend, then: .tokens)),
                .history(key: "usageEvents", provider: provider, .measure("Usage Events", .usageEvents, over: .lastDays(30)))
            ]
        case .antigravity:
            [
                .percent(key: "geminiPro", provider: provider, title: "Gemini 5h",
                         metricLabel: AntigravityMetric.sessionLabel, sessionStartSignal: .zeroUsage)
                    .exportingLimit("geminiSession", unit: "percent")
                    .pinnedByDefault(),
                .percent(key: "geminiWeekly", provider: provider, title: "Gemini", metricLabel: AntigravityMetric.weeklyLabel)
                    .exportingLimit("geminiWeekly", unit: "percent")
                    .pinnedByDefault(),
                .percent(key: "argonWeekly", provider: provider, title: "Argon", metricLabel: AntigravityMetric.argonWeeklyLabel)
                    .exportingLimit("argonWeekly", unit: "percent"),
                .percent(key: "claude", provider: provider, title: "Claude 5h",
                         metricLabel: AntigravityMetric.claudeLabel, sessionStartSignal: .zeroUsage)
                    .exportingLimit("nonGeminiSession", unit: "percent"),
                .percent(key: "claudeWeekly", provider: provider, title: "Claude", metricLabel: AntigravityMetric.claudeWeeklyLabel)
                    .exportingLimit("nonGeminiWeekly", unit: "percent")
            ]
        case .copilot where account.organization != nil:
            [
                .values(key: "orgCredits", provider: provider, title: "Org Credits")
                    .exportingLimit("orgCredits", unit: "credits", source: .value(kind: .count, label: "credits"))
                    .pinnedByDefault(),
                .values(key: "orgSpend", provider: provider, title: "Org Spend", valueWord: "spent")
                    .exportingLimit("orgSpend", unit: "usd", source: .value(kind: .dollars))
            ]
        case .copilot:
            [
                .percent(key: "premium", provider: provider, title: "Credits", metricLabel: "Credits")
                    .exportingLimit("premiumCredits", unit: "credits", source: .progressOrValue(kind: .count))
                    .pinnedByDefault(),
                .values(key: "extra", provider: provider, title: "Extra Usage")
                    .exportingLimit("extraUsage", unit: "count", source: .value(kind: .count)),
                .boundedCount(key: "chat", provider: provider, title: "Chat", limit: 0)
                    .exportingLimit("chat", unit: "percent"),
                .boundedCount(key: "completions", provider: provider, title: "Completions", limit: 0)
                    .exportingLimit("completions", unit: "percent")
            ]
        case .devin:
            [
                .percent(key: "daily", provider: provider, title: "Daily", metricLabel: "Daily quota")
                    .exportingLimit("daily", unit: "percent")
                    .pinnedByDefault(),
                .percent(key: "weekly", provider: provider, title: "Weekly", metricLabel: "Weekly quota")
                    .exportingLimit("weekly", unit: "percent")
                    .pinnedByDefault(),
                .dollarBalance(key: "extra", provider: provider, title: "Extra Usage", metricLabel: "Extra usage balance", valueWord: "left")
                    .exportingLimit("extraUsageBalance", kind: .balance, unit: "usd", source: .value(kind: .dollars))
            ]
        case .grok:
            [
                .percent(key: "weekly", provider: provider, title: "Weekly", metricLabel: "Weekly limit")
                    .exportingLimit("weekly", unit: "percent")
                    .pinnedByDefault(),
                .badge(key: "payAsYouGo", provider: provider, title: "Extra Usage", metricLabel: "Pay as you go")
            ]
        case .ollama:
            [
                .percent(key: "session", provider: provider, title: "Session")
                    .exportingLimit("session", unit: "percent"),
                .percent(key: "weekly", provider: provider, title: "Weekly")
                    .exportingLimit("weekly", unit: "percent"),
                .percent(key: "monthly", provider: provider, title: "Monthly")
                    .exportingLimit("monthly", unit: "percent")
                    .pinnedByDefault(),
                .dollarBalance(key: "purchasedCredits", provider: provider, title: "Extra Usage", metricLabel: "Purchased Credits", valueWord: "left")
                    .exportingLimit("purchasedCredits", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
                .history(key: "today", provider: provider, .window(.today, .usageValue, then: .tokens)),
                .history(key: "yesterday", provider: provider, .window(.yesterday, .usageValue, then: .tokens)),
                .history(key: "last30", provider: provider, .window(.lastDays(30), .usageValue, then: .tokens)),
                .history(key: "requests", provider: provider, .measure("Requests", .requests, over: .lastDays(30)))
            ]
        case .opencodeGo:
            [
                .percent(key: "session", provider: provider, title: "Session", sessionStartSignal: .missingResetDate)
                    .exportingLimit("session", unit: "percent")
                    .pinnedByDefault(),
                .percent(key: "weekly", provider: provider, title: "Weekly")
                    .exportingLimit("weekly", unit: "percent"),
                .percent(key: "monthly", provider: provider, title: "Monthly")
                    .exportingLimit("monthly", unit: "percent")
            ]
        case .openrouter:
            [
                .boundedDollars(key: "credits", provider: provider, title: "Credits", limit: 100)
                    .exportingLimit("credits", unit: "usd")
                    .pinnedByDefault(),
                .dollarBalance(key: "balance", provider: provider, title: "Balance", valueWord: "left")
                    .exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
                .history(key: "today", provider: provider, .window(.today, .spend, then: .byokSpend))
                    .pinnedByDefault(),
                .history(key: "yesterday", provider: provider, .window(.yesterday, .spend, then: .tokens)),
                .history(key: "week", provider: provider, .window(.thisWeek, .spend, then: .byokSpend)),
                .history(key: "month", provider: provider, .window(.thisMonth, .spend, then: .byokSpend)),
                .history(key: "prior30", provider: provider, .window(.priorDays(30), .spend, then: .tokens)),
                .history(key: "requests", provider: provider, .measure("Requests", .requests, over: .priorDays(30))),
                .boundedDollars(key: "keyLimit", provider: provider, title: "Key Limit", limit: 100)
                    .exportingLimit("keyLimit", unit: "usd"),
                .boundedDollars(key: "budget", provider: provider, title: "Budget", limit: 100),
                .boundedCount(key: "freeRequests", provider: provider, title: "Free Requests", limit: 50)
            ]
        case .zai:
            [
                .percent(key: "session", provider: provider, title: "Session")
                    .exportingLimit("session", unit: "percent")
                    .pinnedByDefault(),
                .percent(key: "weekly", provider: provider, title: "Weekly")
                    .exportingLimit("weekly", unit: "percent")
                    .pinnedByDefault(),
                .boundedCount(key: "webSearches", provider: provider, title: "Web Searches", limit: 0)
                    .exportingLimit("webSearches", unit: "searches")
            ]
        }
    }

    private static func rateLimitResets(key: String, provider: Provider) -> WidgetDescriptor {
        .values(key: key, provider: provider, title: "Limit Resets", metricLabel: "Rate Limit Resets",
                traySuffix: "resets", showsResetExpiries: true)
            .exportingLimit("rateLimitResets", kind: .balance, unit: "resets", source: .value(kind: .count, label: "available"))
    }
}

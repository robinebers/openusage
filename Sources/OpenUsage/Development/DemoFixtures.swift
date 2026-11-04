#if OPENUSAGE_DEVELOPMENT
import Foundation

/// Synthetic accounts and readings for the isolated development app. No credential is required.
@MainActor
enum DemoFixtures {
    static let marker = "OPENUSAGE_DEVELOPMENT_DEMO_FIXTURE_V1"

    private static let hub = CLIProxyHub(
        id: UUID(uuid: (0xD3, 0xE0, 0xFF, 0x01, 0x7E, 0x5E, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0)),
        url: URL(string: "https://hub.example.test")!,
        addedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    static func accounts(at now: Date) -> [Account] {
        let mirrored = HubLink(hub: hub, login: HubLogin(
            id: "sample-claude.json", authIndex: "sample-claude", provider: "claude", label: "hub@example.com",
            isOAuth: true, isDisabled: false, chatGPTAccountID: nil
        ))!
        // This is the order these sample accounts are added, not a sort applied to saved accounts.
        let entries: [(ProviderKind, String, String?, HubLink?)] = [
            (.claude, "alex@example.com", nil, nil),
            (.claude, "Work Account", nil, nil),
            (.codex, "sam@example.com", nil, nil),
            (.cursor, "team@example.com", nil, nil),
            (.antigravity, "sky@example.com", nil, nil),
            (.copilot, "developer@example.com", nil, nil),
            (.copilot, "Example Organization", "example-organization", nil),
            (.devin, "builder@example.com", nil, nil),
            (.grok, "grok@example.com", nil, nil),
            (.muse, "muse@example.com", nil, nil),
            (.ollama, "local@example.com", nil, nil),
            (.opencodeGo, "developer@example.com", nil, nil),
            (.openrouter, "router@example.com", nil, nil),
            (.zai, "search@example.com", nil, nil),
            (.claude, "hub@example.com", nil, mirrored),
        ]
        return entries.enumerated().map { index, entry in
            Account(
                id: accountID(UInt8(index + 1)), kind: entry.0, label: entry.1, organization: entry.2, hub: entry.3,
                addedAt: now.addingTimeInterval(Double(index) - 60)
            )
        }
    }

    static func hubs() -> [CLIProxyHub] { [hub] }

    static func snapshot(for account: Account, at now: Date) -> ProviderSnapshot {
        let provider = AccountProviderRuntime.provider(for: account)
        let descriptors = AccountProviderRuntime.widgetDescriptors(for: account)
        var snapshot = ProviderSnapshot(
            provider: provider,
            plan: plan(for: account),
            lines: descriptors.enumerated().compactMap { index, descriptor in
                guard descriptor.historyRow == nil else { return nil }
                return line(for: descriptor, account: account, index: index, at: now)
            },
            notice: account.hub == nil ? nil : "The sample sign-in for hub@example.com at hub.example.test needs attention.",
            refreshedAt: now
        )
        if descriptors.contains(where: { $0.historyRow != nil }) {
            HistoryRow.append(to: &snapshot, for: descriptors, in: history(at: now))
        }
        return snapshot
    }

    private static func accountID(_ index: UInt8) -> UUID {
        UUID(uuid: (0xD3, 0xE0, 0, index, 0x7E, 0x5E, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0))
    }

    private static func line(for descriptor: WidgetDescriptor, account: Account, index: Int, at now: Date) -> MetricLine {
        let label = descriptor.metricLabel
        if descriptor.sample.showsResetExpiries {
            return .values(
                label: label, values: [MetricValue(number: 2, kind: .count, label: "available")],
                expiriesAt: [now.addingTimeInterval(36 * 3_600), now.addingTimeInterval(5 * 86_400)]
            )
        }
        if descriptor.key == "payAsYouGo" { return .badge(label: label, text: "Enabled") }
        guard let sampleLimit = descriptor.sample.limit else {
            return .values(label: label, values: values(for: descriptor, account: account))
        }
        let limit = sampleLimit > 0 ? sampleLimit : countLimit(for: descriptor.key)
        let usage = min(100, baseUsage(for: account) + Double(index % 3) * 4)
        let format: ProgressFormat = switch descriptor.sample.kind {
        case .percent: .percent
        case .dollars: .dollars
        case .count: .count(suffix: "")
        }
        let period = period(for: descriptor)
        return .progress(
            label: label, used: limit * usage / 100, limit: limit, format: format,
            resetsAt: now.addingTimeInterval(period * 0.3), periodDurationMs: Int(period * 1_000)
        )
    }

    private static func values(for descriptor: WidgetDescriptor, account: Account) -> [MetricValue] {
        if account.kind == .codex, descriptor.key == "credits" {
            return CodexUsageMapper.creditValues(remaining: 1_250)
        }
        let source = descriptor.limitResources.first?.source
        let kind: MetricKind
        let label: String?
        switch source {
        case .value(let valueKind, let valueLabel), .progressOrValue(let valueKind, let valueLabel):
            kind = valueKind
            label = valueLabel
        case .progress, nil:
            kind = descriptor.sample.kind
            label = nil
        }
        let number: Double = switch descriptor.key {
        case "orgCredits": 12_450
        case "orgSpend": 42
        case "balance": 18.75
        case "purchasedCredits": 25
        case "credits": 32.5
        default: kind == .count ? 18 : 7.5
        }
        return [MetricValue(number: number, kind: kind, label: label)]
    }

    private static func countLimit(for key: String) -> Double {
        switch key {
        case "creditLimit": 50_000
        case "completions": 5_000
        case "webSearches": 500
        default: 1_000
        }
    }

    private static func period(for descriptor: WidgetDescriptor) -> TimeInterval {
        if let milliseconds = descriptor.sample.periodDurationMs { return Double(milliseconds) / 1_000 }
        let key = descriptor.key.lowercased()
        if key.contains("weekly") { return 7 * 86_400 }
        if key.contains("monthly") { return 30 * 86_400 }
        if key == "daily" { return 86_400 }
        if key == "session" || key.contains("pro") || key == "claude" { return 5 * 3_600 }
        return 30 * 86_400
    }

    private static func baseUsage(for account: Account) -> Double {
        switch account.kind {
        case .claude: account.id == accountID(2) ? 82 : 26
        case .codex: 95
        case .cursor: 100
        case .antigravity: 44
        case .copilot: 12
        case .devin: 57
        case .grok: 68
        case .muse: 34
        case .ollama: 22
        case .opencodeGo: 71
        case .openrouter: 36
        case .zai: 88
        }
    }

    private static func plan(for account: Account) -> String {
        switch account.kind {
        case .claude: "Max 20x"
        case .codex: "Plus"
        case .cursor, .devin, .ollama, .zai: "Pro"
        case .antigravity: "AI Pro"
        case .copilot: account.organization == nil ? "Pro" : "Business"
        case .grok: "SuperGrok"
        case .muse: "Sample Plan"
        case .opencodeGo: "Go"
        case .openrouter: "Pay As You Go"
        }
    }

    private static func history(at now: Date) -> UsageHistory {
        let calendar = Calendar.current
        var history = UsageHistory(calendar: calendar, asOf: now)
        for (index, day) in UsageHistory.dayStarts(0...30, now: now, calendar: calendar).enumerated() {
            let scale = 1 + Double(index % 5) / 10
            let totals = UsageTotals(values: [
                .spend: 2.4 * scale, .usageValue: 1.8 * scale, .credits: 60 * scale,
                .requests: 128 * scale, .usageEvents: 144 * scale, .turns: 24 * scale,
                .tokens: 1_280_000 * scale, .inputTokens: 740_000 * scale,
                .cacheReadTokens: 280_000 * scale, .outputTokens: 260_000 * scale,
            ])
            history.days[day] = UsageDay(totals: totals, byModel: [
                "Sample Model A": UsageTotals(values: totals.values.mapValues { $0 * 0.6 }),
                "Sample Model B": UsageTotals(values: totals.values.mapValues { $0 * 0.4 }),
            ])
        }
        return history
    }
}
#endif

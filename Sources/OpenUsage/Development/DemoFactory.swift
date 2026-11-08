#if OPENUSAGE_DEVELOPMENT
import Foundation

/// SplitMix64, so one seed draws the same sample data on every run.
struct DemoRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(truncatingIfNeeded: seed)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random sample accounts and readings, shaped by each provider's real metric descriptors.
@MainActor
enum DemoFactory {
    struct Entry {
        let kind: ProviderKind
        var label: String
        var organization: String?
    }

    /// The limit states every shuffle shows at least once, the most particular first.
    enum Scenario: CaseIterable {
        case emptyBalance, useItOrLoseIt, burningFast, usedUp, critical, warning
    }

    private static let hour: TimeInterval = 3_600
    private static let day: TimeInterval = 24 * hour
    private static let week: TimeInterval = 7 * day

    /// Every provider in a random order, each with one to three accounts.
    static func accounts(using random: inout DemoRandom) -> [Entry] {
        var entries: [Entry] = []
        for kind in ProviderKind.allCases.shuffled(using: &random) {
            for _ in 0..<[1, 1, 1, 2, 2, 3].randomElement(using: &random)! {
                if kind == .copilot, Int.random(in: 0..<3, using: &random) == 0 {
                    let organization = ["acme-labs", "northwind", "globex-research"].randomElement(using: &random)!
                    entries.append(Entry(kind: kind, label: organization, organization: organization))
                } else {
                    let name = Bool.random(using: &random) ? email(using: &random) : names.randomElement(using: &random)!
                    entries.append(Entry(kind: kind, label: name))
                }
            }
        }
        let personal = entries.indices.filter { entries[$0].organization == nil }.shuffled(using: &random)
        entries[personal[0]].label = longNames.randomElement(using: &random)!
        entries[personal[1]].label = email(using: &random)
        return entries
    }

    /// One reading per account. Each scenario lands on a random limit that can show it, and one account carries a notice.
    static func snapshots(for accounts: [Account], now: Date, using random: inout DemoRandom) -> [UUID: ProviderSnapshot] {
        let descriptors = accounts.map(AccountProviderRuntime.widgetDescriptors(for:))
        let limits = descriptors.flatMap { $0.filter { $0.historyRow == nil } }
        var scenarios: [String: Scenario] = [:]
        for scenario in Scenario.allCases {
            let open = limits.filter { scenarios[$0.id] == nil && fits(scenario, $0) }
            if let pick = open.randomElement(using: &random) { scenarios[pick.id] = scenario }
        }
        let noticed = accounts.indices.randomElement(using: &random)
        var snapshots: [UUID: ProviderSnapshot] = [:]
        for (index, account) in accounts.enumerated() {
            var lines: [MetricLine] = []
            for (position, descriptor) in descriptors[index].enumerated() where descriptor.historyRow == nil {
                let scenario = scenarios[descriptor.id]
                // Providers report some metrics only on some plans, so after the first each one shows two times in three.
                guard position == 0 || scenario != nil || Int.random(in: 0..<3, using: &random) > 0 else { continue }
                lines.append(line(for: descriptor, scenario: scenario, now: now, using: &random))
            }
            var snapshot = ProviderSnapshot(
                provider: AccountProviderRuntime.provider(for: account),
                plan: plans(for: account).randomElement(using: &random),
                lines: lines,
                notice: index == noticed ? "The provider is reporting delayed usage for this account." : nil,
                refreshedAt: now
            )
            if descriptors[index].contains(where: { $0.historyRow != nil }) {
                HistoryRow.append(to: &snapshot, for: descriptors[index], in: history(now: now, using: &random))
            }
            snapshots[account.id] = snapshot
        }
        return snapshots
    }

    private static func fits(_ scenario: Scenario, _ descriptor: WidgetDescriptor) -> Bool {
        guard scenario != .emptyBalance else {
            return !descriptor.sample.showsResetExpiries && descriptor.limitResources.contains { $0.kind == .balance }
        }
        guard descriptor.sample.limit != nil else { return false }
        switch scenario {
        case .useItOrLoseIt: return descriptor.sample.kind != .dollars && period(of: descriptor) > day
        case .burningFast: return period(of: descriptor) <= week
        case .emptyBalance, .usedUp, .critical, .warning: return true
        }
    }

    private static func line(for descriptor: WidgetDescriptor, scenario: Scenario?, now: Date, using random: inout DemoRandom) -> MetricLine {
        let label = descriptor.metricLabel
        if descriptor.sample.showsResetExpiries {
            let expiries = (0..<Int.random(in: 1...3, using: &random)).map { _ in
                now.addingTimeInterval(.random(in: hour...week, using: &random))
            }.sorted()
            return .values(label: label, values: [MetricValue(number: Double(expiries.count), kind: .count, label: "available")],
                           expiriesAt: expiries)
        }
        guard let sampleLimit = descriptor.sample.limit else {
            guard let resource = descriptor.limitResources.first else { return .badge(label: label, text: "Enabled") }
            return .values(label: label, values: values(for: descriptor, resource: resource, isEmpty: scenario == .emptyBalance, using: &random))
        }
        let period = period(of: descriptor)
        let latest = min(period, week)
        let untilReset: TimeInterval = switch scenario {
        case .burningFast: period * .random(in: 0.6...0.85, using: &random)
        case .useItOrLoseIt: .random(in: 2 * hour...20 * hour, using: &random)
        case .usedUp, .critical, .warning, .emptyBalance, nil: .random(in: min(hour, latest)...latest, using: &random)
        }
        let share: Double = switch scenario {
        case .usedUp: 1
        case .critical: .random(in: 0.91...0.97, using: &random)
        case .warning: .random(in: 0.72...0.87, using: &random)
        // At most 40% of the window gone with about half used: well over the limit by the reset.
        case .burningFast: .random(in: 0.45...0.65, using: &random)
        case .useItOrLoseIt: .random(in: 0.1...0.4, using: &random)
        // At an even pace or slower, so a limit burns fast only where a scenario puts it.
        case .emptyBalance, nil: (1 - untilReset / period) * .random(in: 0.2...0.95, using: &random)
        }
        let limit: Double = switch descriptor.sample.kind {
        case .dollars: [20, 50, 100, 200].randomElement(using: &random)!
        case .count where sampleLimit == 0: [50, 100, 1_000, 2_000].randomElement(using: &random)!
        case .count, .percent: sampleLimit
        }
        let format: ProgressFormat = switch descriptor.sample.kind {
        case .percent: .percent
        case .dollars: .dollars
        case .count: .count(suffix: "")
        }
        let used = descriptor.sample.kind == .dollars ? (limit * share * 100).rounded() / 100 : (limit * share).rounded()
        return .progress(label: label, used: used, limit: limit, format: format,
                         resetsAt: now.addingTimeInterval(untilReset), periodDurationMs: Int(period * 1_000))
    }

    private static func values(
        for descriptor: WidgetDescriptor, resource: LimitResourceDescriptor, isEmpty: Bool, using random: inout DemoRandom
    ) -> [MetricValue] {
        if descriptor.providerKind == .codex, descriptor.key == "credits" {
            return CodexUsageMapper.creditValues(remaining: isEmpty ? 0 : .random(in: 50...5_000, using: &random))
        }
        let (kind, label): (MetricKind, String?) = switch resource.source {
        case .value(let kind, let label), .progressOrValue(let kind, let label): (kind, label)
        case .progress: (descriptor.sample.kind, nil)
        }
        let number: Double = switch kind {
        case _ where isEmpty: 0
        case .dollars: (Double.random(in: 1...250, using: &random) * 100).rounded() / 100
        case .count, .percent: Double.random(in: 10...20_000, using: &random).rounded()
        }
        return [MetricValue(number: number, kind: kind, label: label)]
    }

    private static func period(of descriptor: WidgetDescriptor) -> TimeInterval {
        if let milliseconds = descriptor.sample.periodDurationMs { return Double(milliseconds) / 1_000 }
        let key = descriptor.key.lowercased()
        let milliseconds = if key == "session" || ["geminipro", "claude", "spark"].contains(key) {
            MetricPeriod.sessionMs
        } else if key == "daily" || key == "freerequests" {
            MetricPeriod.dayMs
        } else if key.contains("weekly") || ["sonnet", "fable"].contains(key) {
            MetricPeriod.weekMs
        } else {
            MetricPeriod.monthMs
        }
        return Double(milliseconds) / 1_000
    }

    private static func plans(for account: Account) -> [String] {
        switch account.kind {
        case .claude: ["Pro", "Max", "Ultra"]
        case .codex: ["Plus", "Pro", "Business"]
        case .cursor: ["Pro", "Pro+", "Ultra"]
        case .antigravity: ["AI Pro", "AI Ultra"]
        case .copilot: account.organization == nil ? ["Free", "Pro", "Pro+"] : ["Business", "Enterprise"]
        case .devin: ["Core", "Team"]
        case .grok: ["SuperGrok", "SuperGrok Heavy"]
        case .muse: ["Free", "Pro"]
        case .ollama: ["Free", "Pro", "Max"]
        case .opencodeGo: ["Go"]
        case .openrouter: ["Pay As You Go"]
        case .zai: ["Lite", "Pro", "Max"]
        }
    }

    private static func history(now: Date, using random: inout DemoRandom) -> UsageHistory {
        let calendar = Calendar.current
        var history = UsageHistory(calendar: calendar, asOf: now)
        let scale = Double.random(in: 0.3...3, using: &random)
        for day in UsageHistory.dayStarts(0...30, now: now, calendar: calendar) {
            let activity = scale * .random(in: 0...1.5, using: &random)
            let totals = UsageTotals(values: [
                .spend: 2.4 * activity, .usageValue: 1.8 * activity, .credits: 60 * activity,
                .requests: (128 * activity).rounded(), .usageEvents: (144 * activity).rounded(), .turns: (24 * activity).rounded(),
                .tokens: 1_280_000 * activity, .inputTokens: 740_000 * activity,
                .cacheReadTokens: 280_000 * activity, .outputTokens: 260_000 * activity,
            ])
            history.days[day] = UsageDay(totals: totals, byModel: [
                "Sample Model A": UsageTotals(values: totals.values.mapValues { $0 * 0.6 }),
                "Sample Model B": UsageTotals(values: totals.values.mapValues { $0 * 0.4 }),
            ])
        }
        return history
    }

    private static func email(using random: inout DemoRandom) -> String {
        let name = ["alex", "sam", "maya", "jordan", "priya", "leo", "nina", "omar"].randomElement(using: &random)!
        return "\(name)@\(["example.com", "example.org", "example.net"].randomElement(using: &random)!)"
    }

    private static let names = ["Work", "Personal", "Side Project", "Team", "Client Work", "Research"]
    private static let longNames = [
        "Platform Engineering Shared Account",
        "Experimental Agents Sandbox (Do Not Delete)",
        "Customer Success Automation Team",
    ]
}
#endif

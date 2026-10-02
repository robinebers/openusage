import Foundation

struct SharedLocalHistorySource: Sendable {
    let family: String
    let scan: @MainActor @Sendable (Date) async -> ProviderUsageHistory?

    static func claude(directories: [String]) -> Self {
        let scanner = ClaudeLogUsageScanner(additionalConfigDirectories: directories)
        return Self(family: "claude") { now in
            let pricing = await ModelPricingStore.shared.current()
            async let native = scanner.scan(now: now, pricing: pricing)
            async let pi = PiUsageScanner.shared.scan(cardID: "claude", now: now, pricing: pricing)
            return await history([native, pi])
        }
    }

    static func codex(homes: [String]) -> Self {
        let scanner = CodexLogUsageScanner(additionalHomes: homes)
        let openCode = OpenCodeCodexUsageScanner()
        return Self(family: "codex") { now in
            let pricing = await ModelPricingStore.shared.current()
            let fallbackModel = CodexFallbackModelSetting.current()
            async let native = scanner.scan(now: now, pricing: pricing, fallbackModel: fallbackModel)
            async let pi = PiUsageScanner.shared.scan(
                cardID: "codex", now: now, pricing: pricing,
                estimateCost: { CodexUsagePricing.estimatedCost(pricing: pricing, model: $0, tokens: $1) }
            )
            async let hosted = openCode.scan(now: now, pricing: pricing)
            return await history([native, pi, hosted])
        }
    }

    private static func history(_ scans: [LogUsageScan?]) -> ProviderUsageHistory? {
        guard !Task.isCancelled, let scan = DailyUsageAccumulator.merged(scans) else { return nil }
        return ProviderUsageHistory(
            series: scan.series, modelUsage: scan.modelUsage,
            unknownModelsByDay: scan.unknownModelsByDay,
            fallbackPricingModelsByDay: scan.fallbackPricingModelsByDay
        )
    }
}

/// Presentation-only history. It never enters account snapshots, disk caches, or sync documents.
@MainActor
final class SharedLocalHistory {
    private var histories: [String: ProviderUsageHistory] = [:]
    private var refreshedAt: [String: Date] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    var onChange: (@MainActor () -> Void)?

    deinit {
        for task in tasks.values { task.cancel() }
    }

    func refresh(_ source: SharedLocalHistorySource, now: Date, force: Bool) {
        guard tasks[source.family] == nil else { return }
        if !force, let previous = refreshedAt[source.family],
           now.timeIntervalSince(previous) < RefreshSetting.interval { return }
        tasks[source.family] = Task { [weak self] in
            let history = await source.scan(now)
            guard let self, !Task.isCancelled else { return }
            self.tasks[source.family] = nil
            if let history {
                self.histories[source.family] = history
                self.refreshedAt[source.family] = now
                self.onChange?()
            }
        }
    }

    func waitForRefreshes() async {
        for task in tasks.values { await task.value }
    }

    func render(
        _ snapshots: [String: ProviderSnapshot],
        providers: [ProviderRuntime],
        now: Date
    ) -> [String: ProviderSnapshot] {
        var rendered = snapshots
        for runtime in providers {
            guard let family = runtime.sharedHistorySource?.family,
                  let history = histories[family] else { continue }
            let local = snapshots[runtime.provider.id] ?? ProviderSnapshot(
                providerID: runtime.provider.id, displayName: runtime.provider.displayName,
                lines: [], refreshedAt: refreshedAt[family] ?? now
            )
            var snapshot = UsageHistorySnapshotRenderer.render(
                local: local, history: history,
                descriptor: UsageHistoryDescriptor(
                    scope: .machineLocal, estimatedCost: true,
                    sourceNote: "Shared across accounts on this Mac (estimated)"
                ), now: now, combined: false
            )
            snapshot.sharedHistoryFamily = family
            rendered[runtime.provider.id] = snapshot
        }
        return rendered
    }
}

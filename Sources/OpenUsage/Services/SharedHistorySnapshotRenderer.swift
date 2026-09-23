import Foundation

enum SharedHistorySnapshotRenderer {
    /// Repeat the freshest local history on every card in its group, including cards whose login
    /// failed. Their own limits, plan, errors, and freshness are never taken from the source card.
    static func render(
        snapshots: [String: ProviderSnapshot],
        providers: [Provider],
        descriptors: [String: UsageHistoryDescriptor],
        now: Date
    ) -> [String: ProviderSnapshot] {
        var sources: [String: ProviderSnapshot] = [:]
        for snapshot in snapshots.values {
            guard let group = snapshot.sharedHistoryGroup, snapshot.usageHistory != nil,
                  descriptors[snapshot.providerID]?.sharedGroup == group else { continue }
            if let existing = sources[group],
               existing.refreshedAt > snapshot.refreshedAt
                || (existing.refreshedAt == snapshot.refreshedAt && existing.providerID < snapshot.providerID) {
                continue
            }
            sources[group] = snapshot
        }
        var result = snapshots
        for provider in providers {
            guard let descriptor = descriptors[provider.id], let group = descriptor.sharedGroup,
                  let history = sources[group]?.usageHistory else { continue }
            var snapshot = snapshots[provider.id] ?? ProviderSnapshot(
                providerID: provider.id, displayName: provider.displayName, lines: [], refreshedAt: .distantPast)
            snapshot.sharedHistoryGroup = group
            snapshot.usageHistory = history
            result[provider.id] = UsageHistorySnapshotRenderer.render(
                local: snapshot, history: history, descriptor: descriptor, now: now, combined: false)
        }
        return result
    }
}

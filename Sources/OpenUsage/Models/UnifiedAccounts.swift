import Foundation

/// Unify Multiple Accounts: a provider's accounts shown as one, with each limit once.
extension DashboardFamily {
    func unifyingAccounts() -> DashboardFamily {
        guard accounts.count > 1 else { return self }
        var family = self
        family.accounts = [.unifying(accounts)]
        return family
    }
}

extension DashboardAccount {
    /// Each limit reads across the accounts that report it, so an account without it changes nothing.
    static func unifying(_ accounts: [DashboardAccount]) -> DashboardAccount {
        let kind = accounts[0].provider.kind
        let provider = Provider(id: "\(kind.rawValue).unified", kind: kind, accountLabel: "\(accounts.count) Accounts")
        let lines = mergedOrder(accounts.map { $0.lines.map(\.descriptor.key) }).compactMap { key in
            DashboardLine.unifying(accounts.compactMap { account in
                account.lines.first { $0.descriptor.key == key }.map { DashboardLine.Member(provider: account.provider, line: $0) }
            }, as: provider)
        }
        let waiting = lines.isEmpty && accounts.allSatisfy { !$0.waitingMetricIDs.isEmpty } ? accounts[0].waitingMetricIDs : []
        return DashboardAccount(provider: provider, lines: lines, waitingMetricIDs: waiting, members: accounts)
    }

    /// Every account's own order, kept: a key one account lacks goes just before the next key it shares with the others.
    static func mergedOrder(_ orders: [[String]]) -> [String] {
        var merged: [String] = []
        for order in orders {
            for (index, key) in order.enumerated() where !merged.contains(key) {
                let next = order[(index + 1)...].lazy.compactMap { merged.firstIndex(of: $0) }.first
                merged.insert(key, at: next ?? merged.endIndex)
            }
        }
        return merged
    }
}

extension DashboardLine {
    static func unifying(_ members: [Member], as provider: Provider) -> DashboardLine? {
        guard let first = members.first?.line else { return nil }
        let bounded = members.filter { $0.line.data.isBounded }
        let pooled = bounded.isEmpty ? members : bounded
        var descriptor = WidgetDescriptor(
            provider: provider, key: first.descriptor.key, metricLabel: first.descriptor.metricLabel, sample: first.descriptor.sample
        )
        descriptor.limitResources = first.descriptor.limitResources
        return DashboardLine(descriptor: descriptor, data: .pooling(pooled.map(\.line.data)), members: pooled)
    }
}

extension WidgetData {
    /// Limits add up what each account used against what each allows, so percents average. Amounts and counts add
    /// up, and a limit is used up only when every account's is.
    static func pooling(_ readings: [WidgetData]) -> WidgetData {
        var data = readings[0]
        data.periodDurationMs = nil
        data.sessionStartSignal = nil
        guard data.isBounded else {
            data.expiriesAt = readings.flatMap(\.expiriesAt).sorted()
            let badges = readings.compactMap(\.valueTextOverride)
            if !badges.isEmpty {
                data.valueTextOverride = badges.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " · ")
                return data
            }
            data.values = summed(readings.flatMap(\.values))
            data.hasData = !data.values.isEmpty
            return data
        }
        let used = readings.reduce(0) { $0 + $1.used }
        let limit = readings.reduce(0) { $0 + ($1.limit ?? 0) }
        guard limit > 0 else { return data }
        let scale = data.kind == .percent ? 100 / limit : 1
        func reading(used: Double) -> WidgetData {
            WidgetData(
                title: data.title, kind: data.kind, currencyCode: data.currencyCode, used: used, limit: limit * scale,
                displayMode: data.displayMode, priorityLimits: data.priorityLimits, resetDisplayMode: data.resetDisplayMode,
                resetsAt: readings.compactMap(\.resetsAt).min(), showsPaceMarks: data.showsPaceMarks
            )
        }
        let pooled = reading(used: used * scale)
        guard pooled.isSpent, !readings.allSatisfy(\.isSpent) else { return pooled }
        return reading(used: limit * scale - leastShown(data.kind))
    }

    private static func leastShown(_ kind: MetricKind) -> Double {
        switch kind {
        case .percent: 1
        case .count: 0.1
        case .dollars: 0.01
        }
    }

    /// Values with the same label, kind and currency add up, in the order they first appear.
    private static func summed(_ values: [MetricValue]) -> [MetricValue] {
        var sums: [MetricValue] = []
        for value in values {
            if let index = sums.firstIndex(where: { $0.label == value.label && $0.kind == value.kind && $0.currencyCode == value.currencyCode }) {
                sums[index].number += value.number
            } else {
                sums.append(value)
            }
        }
        return sums
    }
}

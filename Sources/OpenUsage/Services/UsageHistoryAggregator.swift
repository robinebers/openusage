import Foundation

enum UsageHistoryAggregator {
    /// Combines only providers explicitly declared machine-local. Account-wide histories such as
    /// Cursor are left out even if a malformed or future file contains them.
    static func merged(
        localSnapshots: [String: ProviderSnapshot],
        peerDocuments: [UsageHistoryDocument],
        descriptors: [String: UsageHistoryDescriptor],
        providerIdentityKeys: [String: String] = [:],
        now: Date = Date()
    ) -> [String: ProviderUsageHistory] {
        var inputs: [String: [ProviderUsageHistory]] = [:]
        let peerDocuments = UsageHistoryDocument.newestByDevice(peerDocuments)
        let localClaudeCards = Set(descriptors.keys.filter {
            ProviderAccountID.family(of: $0) == "claude"
        }).union(providerIdentityKeys.keys.filter {
            ProviderAccountID.family(of: $0) == "claude"
        })
        for (providerID, descriptor) in descriptors where descriptor.scope == .machineLocal {
            if let local = localSnapshots[providerID]?.usageHistory {
                inputs[providerID, default: []].append(local)
            }
            for document in peerDocuments {
                let peer: ProviderUsageHistory?
                if ProviderAccountID.family(of: providerID) == "claude" {
                    peer = claudeHistory(
                        in: document,
                        providerID: providerID,
                        identity: providerIdentityKeys[providerID],
                        allowsUnattributedHistory: localClaudeCards.count <= 1
                    )
                } else {
                    peer = document.providers[providerID]
                }
                if let peer {
                    inputs[providerID, default: []].append(peer)
                }
            }
        }
        let includedDays = UsageHistoryWindow.dayKeys(through: now)
        return inputs.mapValues { merge($0, includedDays: includedDays) }
    }

    private static func claudeHistory(
        in document: UsageHistoryDocument,
        providerID: String,
        identity: String?,
        allowsUnattributedHistory: Bool
    ) -> ProviderUsageHistory? {
        if let identities = document.identities,
           identities.keys.contains(where: { ProviderAccountID.family(of: $0) == "claude" })
        {
            guard let identity,
                  let matchingID = identities.first(where: {
                      ProviderAccountID.family(of: $0.key) == "claude"
                          && $0.value.caseInsensitiveCompare(identity) == .orderedSame
                  })?.key
            else { return nil }
            return document.providers[matchingID]
        }

        guard document.schema == UsageHistoryDocument.currentSchema,
              allowsUnattributedHistory
        else { return nil }
        return document.providers["claude"]
    }

    private static func merge(
        _ histories: [ProviderUsageHistory],
        includedDays: Set<String>
    ) -> ProviderUsageHistory {
        var days: [String: (tokens: Int, cost: Double?, sawCost: Bool)] = [:]
        var models: [String: [String: ModelAccumulator]] = [:]
        var unknown: [String: Set<String>] = [:]
        var fallbackModelsByDay: [String: Set<String>] = [:]

        for history in histories {
            for day in history.series.daily where includedDays.contains(day.date) {
                if let fallbackModels = history.fallbackPricingModelsByDay?[day.date] {
                    fallbackModelsByDay[day.date, default: []].formUnion(fallbackModels)
                }
                var value = days[day.date] ?? (0, nil, false)
                value.tokens += day.totalTokens
                if let cost = day.costUSD {
                    value.cost = (value.cost ?? 0) + cost
                    value.sawCost = true
                }
                days[day.date] = value
            }
            for day in history.modelUsage?.daily ?? [] where includedDays.contains(day.date) {
                for model in day.models {
                    models[day.date, default: [:]][model.model.lowercased(), default: ModelAccumulator()]
                        .add(model)
                }
            }
            for (day, names) in history.unknownModelsByDay where includedDays.contains(day) {
                unknown[day, default: []].formUnion(names)
            }
        }

        let series = DailyUsageSeries(daily: days.map { date, value in
            DailyUsageEntry(
                date: date,
                totalTokens: value.tokens,
                costUSD: value.sawCost ? value.cost : nil
            )
        }.sorted { $0.date > $1.date })

        let modelDays = models.map { date, byName in
            DailyModelUsageEntry(
                date: date,
                models: byName.values.map(\.entry).sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending }
            )
        }.sorted { $0.date > $1.date }

        return ProviderUsageHistory(
            series: series,
            modelUsage: modelDays.isEmpty ? nil : ModelUsageSeries(daily: modelDays),
            unknownModelsByDay: unknown,
            fallbackPricingModelsByDay: fallbackModelsByDay.isEmpty ? nil : fallbackModelsByDay
        )
    }

    private struct ModelAccumulator {
        var displayName = ""
        var tokens = 0
        var cost: Double?
        var sawCost = false
        var variants: [String: VariantAccumulator] = [:]

        mutating func add(_ model: ModelUsageEntry) {
            if displayName.isEmpty { displayName = model.model }
            tokens += model.totalTokens
            if let value = model.costUSD {
                cost = (cost ?? 0) + value
                sawCost = true
            }
            for variant in model.variants ?? [] {
                variants[variant.model.lowercased(), default: VariantAccumulator(name: variant.model)]
                    .add(variant)
            }
        }

        var entry: ModelUsageEntry {
            let mergedVariants = variants.values.map(\.entry)
                .sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending }
            return ModelUsageEntry(
                model: displayName,
                totalTokens: tokens,
                costUSD: sawCost ? cost : nil,
                variants: mergedVariants.isEmpty ? nil : mergedVariants
            )
        }
    }

    private struct VariantAccumulator {
        var name: String
        var tokens = 0
        var cost: Double?
        var sawCost = false

        mutating func add(_ variant: ModelUsageVariant) {
            tokens += variant.totalTokens
            if let value = variant.costUSD {
                cost = (cost ?? 0) + value
                sawCost = true
            }
        }

        var entry: ModelUsageVariant {
            ModelUsageVariant(model: name, totalTokens: tokens, costUSD: sawCost ? cost : nil)
        }
    }
}

enum UsageHistorySnapshotRenderer {
    private static let historyLabels: Set<String> = ["Today", "Yesterday", "Last 30 Days", "Usage Trend"]

    static func render(
        local snapshot: ProviderSnapshot,
        history: ProviderUsageHistory,
        descriptor: UsageHistoryDescriptor,
        now: Date = Date(),
        combined: Bool = true
    ) -> ProviderSnapshot {
        var result = snapshot
        result.lines.removeAll { historyLabels.contains($0.label) }
        let baseNote = combined ? "Across your Macs · \(descriptor.sourceNote)" : descriptor.sourceNote
        SpendTileMapper.appendTokenUsage(
            history.series,
            to: &result.lines,
            now: now,
            estimated: descriptor.estimatedCost,
            unknownModelsByDay: history.unknownModelsByDay,
            modelUsage: history.modelUsage,
            modelSourceNote: baseNote,
            fallbackPricingModelsByDay: history.fallbackPricingModelsByDay
        )
        SpendTileMapper.appendUsageTrend(
            history.series,
            to: &result.lines,
            now: now,
            note: baseNote,
            fallbackPricingModelsByDay: history.fallbackPricingModelsByDay
        )
        return result
    }
}

extension LayoutStore {
    func provider(id: String) -> Provider? { registry.provider(id: id) }

    func isMetricEnabled(_ descriptorID: String) -> Bool {
        !hiddenMetricIDs.contains(descriptorID)
    }

    /// The shown metrics in the user's order: provider order, then each provider's metric order.
    var visibleDescriptors: [WidgetDescriptor] { displayGroups.flatMap(\.metrics) }

    // MARK: - Provider grouping

    /// Accounts in the user's saved order. A new account joins the bottom of its provider's accounts, and
    /// a provider's first account goes to the bottom of the list.
    func orderedProviderIDs() -> [String] {
        registry.orderedProviderIDs(savedOrder: providerOrder)
    }

    /// Every account's provider in the user's saved order. Also the Accounts list (L1).
    func orderedProviders() -> [Provider] {
        orderedProviderIDs().compactMap { registry.provider(id: $0) }
    }

    /// Shown metrics grouped by provider, in the user's provider order, each provider's metrics kept in
    /// the provider's custom metric order. Drives the grouped dashboard list; providers with no shown
    /// metric are dropped so the dashboard only shows groups that have something to show.
    var displayGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            let metrics = orderedSupportedMetrics(for: provider.id).filter { !hiddenMetricIDs.contains($0.id) }
            return metrics.isEmpty ? nil : ProviderMetrics(provider: provider, metrics: metrics)
        }
    }

    /// The Accounts detail (L2) for one account: every metric it supports, in its saved metric order.
    /// Nil for an unknown provider or one with no metrics.
    func customizeDetail(for providerID: String) -> ProviderMetrics? {
        guard let provider = registry.provider(id: providerID) else { return nil }
        let metrics = orderedSupportedMetrics(for: providerID)
        return metrics.isEmpty ? nil : ProviderMetrics(provider: provider, metrics: metrics)
    }

    /// A provider's supported metrics in custom order, independent of whether each metric is enabled.
    func orderedSupportedMetrics(for providerID: String) -> [WidgetDescriptor] {
        metricOrder(for: providerID).compactMap { registry.descriptor(id: $0) }
    }

    /// Pinned metrics grouped by provider, in the user's saved order (provider order, then each
    /// provider's metric order). Drives the menu-bar strip.
    var pinnedGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            let metrics = orderedSupportedMetrics(for: provider.id).filter { pinnedMetricIDs.contains($0.id) }
            return metrics.isEmpty ? nil : ProviderMetrics(provider: provider, metrics: metrics)
        }
    }

    /// Reorder whole providers when `dragged`'s header is dropped onto `target`'s.
    /// Returns whether the order actually changed — the drag gestures key haptics off it.
    @discardableResult
    func reorderProvider(dragged: String, target: String) -> Bool {
        recordingUndoStep {
            let ordered = orderedProviderIDs()
            guard let next = Self.reordered(ordered, dragged: dragged, target: target) else { return false }
            providerOrder = next
            persistProviderOrder()
            return true
        }
    }

    /// Move a whole provider card: every account of `dragged`'s provider family moves, in its own order,
    /// to `target`'s place. Accounts of one family stay together in the saved order afterwards.
    @discardableResult
    func reorderFamily(dragged: String, target: String) -> Bool {
        recordingUndoStep {
            var families: [String] = []
            var members: [String: [String]] = [:]
            for provider in orderedProviders() {
                let family = provider.kind.rawValue
                if members[family] == nil { families.append(family) }
                members[family, default: []].append(provider.id)
            }
            guard let next = Self.reordered(families, dragged: dragged, target: target) else { return false }
            providerOrder = next.flatMap { members[$0] ?? [] }
            persistProviderOrder()
            return true
        }
    }

    /// Reorder metrics within one provider when `dragged` is dropped onto `target` (both descriptor ids of
    /// that provider). Operates on the provider's full metric order so disabled metrics keep their place too.
    /// Returns whether the order actually changed — the drag gestures key haptics off it.
    @discardableResult
    func reorderMetric(dragged: String, target: String, in providerID: String) -> Bool {
        recordingUndoStep {
            guard let next = Self.reordered(metricOrder(for: providerID), dragged: dragged, target: target) else {
                return false
            }
            metricOrderByProvider[providerID] = next
            persistMetricOrder()
            return true
        }
    }

    /// Pure reorder: remove `dragged`, reinsert it adjacent to `target` (after it when moving down, before
    /// it when moving up). Returns nil when either id is missing or they're identical. Mirrors the proven
    /// macOS drag-reorder math from crafcat7/Peakmon (Apache-2.0).
    static func reordered(_ ids: [String], dragged: String, target: String) -> [String]? {
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target) else { return nil }
        var next = ids
        next.remove(at: from)
        guard let adjusted = next.firstIndex(of: target) else { return nil }
        let insert = from < to ? adjusted + 1 : adjusted
        next.insert(dragged, at: min(insert, next.count))
        return next
    }
}

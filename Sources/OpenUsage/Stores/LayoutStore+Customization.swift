extension LayoutStore {
    func provider(id: String) -> Provider? { registry.provider(id: id) }

    func isMetricEnabled(_ descriptorID: String) -> Bool {
        !state.hiddenMetricIDs.contains(descriptorID)
    }

    var visibleDescriptors: [WidgetDescriptor] { displayGroups.flatMap(\.metrics) }

    func orderedProviderIDs() -> [String] {
        registry.orderedProviderIDs(savedOrder: state.providerOrder)
    }

    func orderedProviders() -> [Provider] {
        orderedProviderIDs().compactMap { registry.provider(id: $0) }
    }

    var displayGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            let metrics = orderedSupportedMetrics(for: provider.id).filter { !state.hiddenMetricIDs.contains($0.id) }
            return metrics.isEmpty ? nil : ProviderMetrics(provider: provider, metrics: metrics)
        }
    }

    func customizeDetail(for providerID: String) -> ProviderMetrics? {
        guard let provider = registry.provider(id: providerID) else { return nil }
        let metrics = orderedSupportedMetrics(for: providerID)
        return metrics.isEmpty ? nil : ProviderMetrics(provider: provider, metrics: metrics)
    }

    func orderedSupportedMetrics(for providerID: String) -> [WidgetDescriptor] {
        metricOrder(for: providerID).compactMap { registry.descriptor(id: $0) }
    }

    var pinnedGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            let metrics = orderedSupportedMetrics(for: provider.id).filter { state.pinnedMetricIDs.contains($0.id) }
            return metrics.isEmpty ? nil : ProviderMetrics(provider: provider, metrics: metrics)
        }
    }

    @discardableResult
    func reorderProvider(dragged: String, target: String) -> Bool {
        recordingUndoStep {
            let ordered = orderedProviderIDs()
            guard let next = Self.reordered(ordered, dragged: dragged, target: target) else { return false }
            state.providerOrder = next
            persist()
            return true
        }
    }

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
            state.providerOrder = next.flatMap { members[$0] ?? [] }
            persist()
            return true
        }
    }

    @discardableResult
    func reorderMetric(dragged: String, target: String, in providerID: String) -> Bool {
        recordingUndoStep {
            guard let next = Self.reordered(metricOrder(for: providerID), dragged: dragged, target: target) else {
                return false
            }
            state.metricOrderByProvider[providerID] = next
            persist()
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

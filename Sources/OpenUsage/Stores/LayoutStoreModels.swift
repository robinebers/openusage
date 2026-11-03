struct ProviderMetrics: Identifiable {
    let provider: Provider
    let metrics: [WidgetDescriptor]
    var id: String { provider.id }
}

struct LayoutState: Codable, Equatable {
    var hiddenMetricIDs: Set<String> = []
    /// Metrics listed under Pinned at the top of Priority. Not `pinnedMetricIDs`, which held the old menu-bar stars.
    var priorityPinIDs: Set<String> = []
    var providerOrder: [String] = []
    var metricOrderByProvider: [String: [String]] = [:]
    /// Accounts that already had their chance at a 0.7.x layout, so the user's later order is never replaced.
    var seededProviderIDs: Set<String> = []
}

extension LayoutState {
    /// A layout saved while this build had no hiding or pins has none.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenMetricIDs = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenMetricIDs) ?? []
        priorityPinIDs = try container.decodeIfPresent(Set<String>.self, forKey: .priorityPinIDs) ?? []
        providerOrder = try container.decode([String].self, forKey: .providerOrder)
        metricOrderByProvider = try container.decode([String: [String]].self, forKey: .metricOrderByProvider)
        seededProviderIDs = try container.decode(Set<String>.self, forKey: .seededProviderIDs)
    }
}

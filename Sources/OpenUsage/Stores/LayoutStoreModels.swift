struct ProviderMetrics: Identifiable {
    let provider: Provider
    let metrics: [WidgetDescriptor]
    var id: String { provider.id }
}

struct LayoutState: Codable, Equatable {
    var providerOrder: [String] = []
    var metricOrderByProvider: [String: [String]] = [:]
    /// Accounts that already had their chance at a 0.7.x layout, so the user's later order is never replaced.
    var seededProviderIDs: Set<String> = []
}

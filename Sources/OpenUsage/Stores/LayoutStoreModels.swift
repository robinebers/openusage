struct ProviderMetrics: Identifiable {
    let provider: Provider
    let metrics: [WidgetDescriptor]
    var id: String { provider.id }
}

enum CustomizationNoticeTone {
    case positive
    case notice
}

struct CustomizationNoticeContent {
    var message: String
    var tone: CustomizationNoticeTone
}

struct LayoutSnapshot: Equatable {
    let hiddenMetricIDs: Set<String>
    let providerOrder: [String]
    let metricOrderByProvider: [String: [String]]
    let pinnedMetricIDs: Set<String>
}

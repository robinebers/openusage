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

struct LayoutState: Codable, Equatable {
    var hiddenMetricIDs: Set<String> = []
    var providerOrder: [String] = []
    var metricOrderByProvider: [String: [String]] = [:]
    var pinnedMetricIDs: Set<String> = []
    /// Accounts that already got their first stars, so a star the user takes off is never put back.
    var seededProviderIDs: Set<String> = []
}

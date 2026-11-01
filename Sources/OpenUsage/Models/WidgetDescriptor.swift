import Foundation

struct WidgetDescriptor: Identifiable, Hashable {
    let id: String
    let providerID: String
    let providerKind: ProviderKind
    let key: String
    let metricLabel: String
    let sample: WidgetData
    var limitResources: [LimitResourceDescriptor] = []
    var isPinnedByDefault = false
    var historyRow: HistoryRow?

    init(provider: Provider, key: String, metricLabel: String, sample: WidgetData) {
        id = "\(provider.id).\(key)"
        providerID = provider.id
        providerKind = provider.kind
        self.key = key
        self.metricLabel = metricLabel
        self.sample = sample
    }

    var kindScopedKey: String { "\(providerKind.rawValue).\(key)" }

    func pinnedByDefault() -> WidgetDescriptor {
        var copy = self
        copy.isPinnedByDefault = true
        return copy
    }

    var title: String { sample.title }

    static func == (lhs: WidgetDescriptor, rhs: WidgetDescriptor) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

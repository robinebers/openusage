import Foundation

struct WidgetDescriptor: Identifiable, Hashable {
    let id: String
    let providerID: String
    let providerKind: ProviderKind
    let key: String
    let metricLabel: String
    let sample: WidgetData
    var limitResources: [LimitResourceDescriptor] = []
    var historyRow: HistoryRow?
    /// What the row reads when the provider reports nothing for it; nil hides the row instead.
    var unreportedValues: [MetricValue]?

    init(provider: Provider, key: String, metricLabel: String, sample: WidgetData) {
        id = "\(provider.id).\(key)"
        providerID = provider.id
        providerKind = provider.kind
        self.key = key
        self.metricLabel = metricLabel
        self.sample = sample
    }

    var kindScopedKey: String { "\(providerKind.rawValue).\(key)" }

    var title: String { sample.title }

    /// What's left of an open balance: money or credits the user holds, with no limit to measure it
    /// against. Limit Resets export as a balance too, but having none is not having run out of anything.
    func balance(in data: WidgetData) -> MetricValue? {
        guard !sample.showsResetExpiries, data.hasData, data.limit == nil else { return nil }
        return limitResources.first { $0.kind == .balance }?.value(in: data.values)
    }

    static func == (lhs: WidgetDescriptor, rhs: WidgetDescriptor) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

import Foundation

struct WidgetRegistry: Sendable {
    let providers: [Provider]
    let descriptors: [WidgetDescriptor]

    private let descriptorsByID: [String: WidgetDescriptor]
    private let providersByID: [String: Provider]
    private let descriptorsByProvider: [String: [WidgetDescriptor]]

    init(providers: [Provider], descriptors: [WidgetDescriptor]) {
        self.providers = providers
        self.descriptors = descriptors
        self.descriptorsByID = Dictionary(
            descriptors.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.providersByID = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var byProvider: [String: [WidgetDescriptor]] = [:]
        for descriptor in descriptors {
            byProvider[descriptor.providerID, default: []].append(descriptor)
        }
        self.descriptorsByProvider = byProvider
    }

    func descriptor(id: String) -> WidgetDescriptor? { descriptorsByID[id] }
    func provider(id: String) -> Provider? { providersByID[id] }
    func descriptors(for providerID: String) -> [WidgetDescriptor] {
        descriptorsByProvider[providerID] ?? []
    }

    func orderedProviderIDs(savedOrder: [String]) -> [String] {
        let known = Set(providers.map(\.id))
        var ordered = savedOrder.filter { known.contains($0) }
        let savedIDs = Set(ordered)
        for provider in providers where !savedIDs.contains(provider.id) {
            if let last = ordered.lastIndex(where: { providersByID[$0]?.kind == provider.kind }) {
                ordered.insert(provider.id, at: last + 1)
            } else {
                ordered.append(provider.id)
            }
        }
        return ordered
    }

    @MainActor
    static func from(_ runtimes: [ProviderRuntime]) -> WidgetRegistry {
        let providers = runtimes.map(\.provider)
        let metrics = runtimes.flatMap(\.widgetDescriptors)
        return WidgetRegistry(providers: providers, descriptors: metrics)
    }
}

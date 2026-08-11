import Foundation

/// Read-only catalog of providers and the widgets they register, built from the live
/// `ProviderRuntime`s at launch.
///
/// The registry is immutable once built, and its lookups are read on every render through
/// `LayoutStore`'s `@Observable` computed properties (display groups, metric order, pin counts).
/// So the three accessors are backed by lookup maps precomputed once at construction — O(1)/O(k)
/// instead of linear scans of every descriptor on every call.
struct WidgetRegistry: Sendable {
    let providers: [Provider]
    let descriptors: [WidgetDescriptor]

    /// Descriptor by id — backs `descriptor(id:)`.
    private let descriptorsByID: [String: WidgetDescriptor]
    /// Provider by id — backs `provider(id:)`.
    private let providersByID: [String: Provider]
    /// Per-provider descriptor lists, preserving the original `descriptors` order within each provider
    /// (a stable `filter` walk), so `descriptors(for:)` returns the exact sequence the UI metric order
    /// depends on.
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

    /// Saved order filtered to installed providers, with newly introduced providers appended in the
    /// canonical registry order. Shared by the dashboard, local API, and one-shot CLI.
    func orderedProviderIDs(savedOrder: [String]) -> [String] {
        let defaults = providers.map(\.id)
        let known = Set(defaults)
        let saved = savedOrder.filter { known.contains($0) }
        let savedIDs = Set(saved)
        return saved + defaults.filter { !savedIDs.contains($0) }
    }

    var limitDescriptorsByProvider: [String: [WidgetDescriptor]] {
        descriptorsByProvider.mapValues { $0.filter { !$0.limitResources.isEmpty } }
    }

    var historyDescriptorsByProvider: [String: UsageHistoryDescriptor] {
        descriptorsByProvider.compactMapValues { descriptors in
            descriptors.compactMap(\.historyResource).first
        }
    }

    @MainActor
    static func from(_ runtimes: [ProviderRuntime]) -> WidgetRegistry {
        let providers = runtimes.map(\.provider)
        let metrics = runtimes.flatMap(\.widgetDescriptors)
        return WidgetRegistry(providers: providers, descriptors: metrics)
    }
}

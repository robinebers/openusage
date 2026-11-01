import SwiftUI
import Observation

@MainActor
@Observable
final class LayoutStore {
    var state = LayoutState()

    static let maxUndoDepth = 40
    private var undoSnapshots: [LayoutState] = []
    private var isApplyingUndo = false

    private(set) var registry: WidgetRegistry
    private let defaults: UserDefaults
    private let persistence: LayoutPersistence

    init(registry: WidgetRegistry, defaults: UserDefaults = .standard) {
        self.registry = registry
        self.defaults = defaults
        self.persistence = LayoutPersistence(defaults: defaults)
        loadLayout()
    }

    func apply(registry: WidgetRegistry) {
        if Set(registry.providers.map(\.id)) != Set(self.registry.providers.map(\.id)) { undoSnapshots.removeAll() }
        self.registry = registry
        loadLayout()
    }

    private func loadLayout() {
        var saved = persistence.load() ?? LayoutState()
        let unseeded = registry.providers.filter { !saved.seededProviderIDs.contains($0.id) }
        for provider in unseeded { seed(provider, into: &saved) }
        if !unseeded.isEmpty {
            saved.providerOrder = registry.orderedProviderIDs(savedOrder: saved.providerOrder)
            persistence.save(saved)
        }

        state = LayoutState(
            providerOrder: saved.providerOrder,
            metricOrderByProvider: saved.metricOrderByProvider.filter { registry.provider(id: $0.key) != nil },
            seededProviderIDs: saved.seededProviderIDs.filter { registry.provider(id: $0) != nil }
        )
    }

    /// The only account of its provider takes that provider's 0.7.x order.
    private func seed(_ provider: Provider, into saved: inout LayoutState) {
        saved.seededProviderIDs.insert(provider.id)
        let metrics = registry.descriptors(for: provider.id)
        let others = registry.orderedProviderIDs(savedOrder: saved.providerOrder)
            .filter { $0 != provider.id }
            .compactMap { registry.provider(id: $0) }
        guard !others.contains(where: { $0.kind == provider.kind }),
              let carried = LayoutV1Keys(defaults: defaults).carriedOver(to: provider, metrics: metrics, among: others)
        else { return }
        if let order = carried.metricOrder { saved.metricOrderByProvider[provider.id] = order }
        if let index = carried.providerIndex {
            var providers = others.map(\.id)
            providers.insert(provider.id, at: index)
            saved.providerOrder = providers
        }
        AppLog.notice(.config, "layout: \(provider.id) takes its provider's 0.7.x layout")
    }

    var canUndo: Bool { !undoSnapshots.isEmpty }

    func recordingUndoStep<T>(_ body: () -> T) -> T {
        guard !isApplyingUndo else { return body() }
        let before = state
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        let result = body()
        if state != before {
            undoSnapshots.append(before)
            if undoSnapshots.count > Self.maxUndoDepth { undoSnapshots.removeFirst() }
        }
        return result
    }

    @discardableResult
    func undo() -> Bool {
        guard let snapshot = undoSnapshots.popLast() else { return false }
        state = snapshot
        persist()
        return true
    }

    func persist() {
        persistence.save(state)
    }

    func metricOrder(for providerID: String) -> [String] {
        let valid = registry.descriptors(for: providerID).map(\.id)
        let validSet = Set(valid)
        var seen = Set<String>()
        let saved = (state.metricOrderByProvider[providerID] ?? []).filter { id in
            validSet.contains(id) && seen.insert(id).inserted
        }
        return saved + valid.filter { !seen.contains($0) }
    }
}

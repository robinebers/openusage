import SwiftUI
import Observation

@MainActor
@Observable
final class LayoutStore {
    var state = LayoutState()

    var pinnedMetricIDs: Set<String> { state.pinnedMetricIDs }

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
        undoSnapshots.removeAll()
        self.registry = registry
        loadLayout()
    }

    private func loadLayout() {
        var saved = persistence.load() ?? LayoutState()
        let unseeded = registry.providers.filter { !saved.seededProviderIDs.contains($0.id) }
        for provider in unseeded { seed(provider, into: &saved) }
        if !unseeded.isEmpty { persistence.save(saved) }

        let hidden = saved.hiddenMetricIDs.filter { registry.descriptor(id: $0) != nil }
        state = LayoutState(
            hiddenMetricIDs: hidden,
            providerOrder: saved.providerOrder,
            metricOrderByProvider: saved.metricOrderByProvider.filter { registry.provider(id: $0.key) != nil },
            pinnedMetricIDs: saved.pinnedMetricIDs.filter { registry.descriptor(id: $0) != nil && !hidden.contains($0) },
            seededProviderIDs: saved.seededProviderIDs.filter { registry.provider(id: $0) != nil }
        )
    }

    /// The only account of its provider takes that provider's 0.7.x layout. Any other account starts
    /// with its default stars.
    private func seed(_ provider: Provider, into saved: inout LayoutState) {
        saved.seededProviderIDs.insert(provider.id)
        let metrics = registry.descriptors(for: provider.id)
        let others = registry.orderedProviderIDs(savedOrder: saved.providerOrder)
            .filter { $0 != provider.id }
            .compactMap { registry.provider(id: $0) }
        guard !others.contains(where: { $0.kind == provider.kind }),
              let carried = LayoutV1Keys(defaults: defaults).carriedOver(to: provider, metrics: metrics, among: others)
        else {
            let stars = metrics.filter { $0.isPinnedByDefault && !saved.hiddenMetricIDs.contains($0.id) }
            saved.pinnedMetricIDs.formUnion(stars.map(\.id))
            return
        }
        saved.hiddenMetricIDs.formUnion(carried.hidden)
        saved.pinnedMetricIDs.formUnion(carried.stars)
        if let order = carried.metricOrder { saved.metricOrderByProvider[provider.id] = order }
        if let index = carried.providerIndex {
            var providers = others.map(\.id)
            providers.insert(provider.id, at: index)
            saved.providerOrder = providers
        }
        AppLog.notice(.config, "layout: \(provider.id) takes its provider's 0.7.x layout")
    }

    func setMetricEnabled(_ descriptorID: String, _ enabled: Bool) {
        recordingUndoStep {
            if enabled { show(descriptorID) } else { hide(descriptorID) }
        }
    }

    func showMetrics(_ descriptorIDs: [String]) {
        recordingUndoStep {
            for id in descriptorIDs { show(id) }
        }
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

    static let maxPinsPerProvider = 2

    func isPinned(_ descriptorID: String) -> Bool { state.pinnedMetricIDs.contains(descriptorID) }

    func pinnedCount(forProvider providerID: String) -> Int {
        state.pinnedMetricIDs.count { registry.descriptor(id: $0)?.providerID == providerID }
    }

    func canPin(_ descriptorID: String) -> Bool {
        if state.pinnedMetricIDs.contains(descriptorID) { return true }
        guard let descriptor = registry.descriptor(id: descriptorID) else { return false }
        if pinnedCount(forProvider: descriptor.providerID) >= Self.maxPinsPerProvider { return false }
        return true
    }

    func pinDenialReason(_ descriptorID: String) -> String? {
        guard !canPin(descriptorID) else { return nil }
        if let providerID = registry.descriptor(id: descriptorID)?.providerID,
           pinnedCount(forProvider: providerID) >= Self.maxPinsPerProvider {
            return "Up to \(Self.maxPinsPerProvider) stars per provider"
        }
        return nil
    }

    func setPinned(_ pinned: Bool, for descriptorID: String) {
        recordingUndoStep {
            if pinned {
                guard canPin(descriptorID), registry.descriptor(id: descriptorID) != nil else { return }
                guard state.pinnedMetricIDs.insert(descriptorID).inserted else { return }
                state.hiddenMetricIDs.remove(descriptorID)
            } else {
                guard state.pinnedMetricIDs.remove(descriptorID) != nil else { return }
            }
            persist()
        }
    }

    func togglePin(_ descriptorID: String) {
        setPinned(!isPinned(descriptorID), for: descriptorID)
    }

    func show(_ descriptorID: String) {
        guard state.hiddenMetricIDs.remove(descriptorID) != nil else { return }
        persist()
    }

    func hide(_ descriptorID: String) {
        guard registry.descriptor(id: descriptorID) != nil, state.hiddenMetricIDs.insert(descriptorID).inserted else { return }
        state.pinnedMetricIDs.remove(descriptorID)
        persist()
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

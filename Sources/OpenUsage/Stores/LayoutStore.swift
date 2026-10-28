import SwiftUI
import Observation

@MainActor
@Observable
final class LayoutStore {
    private(set) var hiddenMetricIDs: Set<String> = []

    var providerOrder: [String] = []
    var metricOrderByProvider: [String: [String]] = [:]

    private(set) var pinnedMetricIDs: Set<String> = []

    static let maxUndoDepth = 40
    private var undoSnapshots: [LayoutSnapshot] = []
    private var isApplyingUndo = false

    private(set) var registry: WidgetRegistry
    private let persistence: LayoutPersistence

    init(registry: WidgetRegistry, defaults: UserDefaults = .standard, storageKey: String = "openusage.layout.v1") {
        self.registry = registry
        self.persistence = LayoutPersistence(defaults: defaults, storageKey: storageKey)
        loadLayout(newCardIDs: [])
    }

    func apply(registry: WidgetRegistry) {
        undoSnapshots.removeAll()
        let knownCardIDs = Set(self.registry.providers.map(\.id))
        self.registry = registry
        loadLayout(newCardIDs: registry.providers.map(\.id).filter { !knownCardIDs.contains($0) })
    }

    private func loadLayout(newCardIDs: [String]) {
        hiddenMetricIDs = Set(persistence.loadHidden() ?? []).filter { registry.descriptor(id: $0) != nil }
        providerOrder = persistence.loadProviderOrder() ?? []
        metricOrderByProvider = persistence.loadMetricOrder().map {
            LayoutOrdering.normalizedMetricOrder($0, registry: registry)
        } ?? LayoutOrdering.defaultMetricOrder(registry: registry)

        let savedPins = persistence.loadPins().map { Set($0).filter { registry.descriptor(id: $0) != nil } }
        let pins = savedPins.map { $0.union(newCardIDs.flatMap(defaultPins(forCard:))) }
            ?? Set(registry.providers.flatMap { defaultPins(forCard: $0.id) })
        pinnedMetricIDs = pins.filter { registry.descriptor(id: $0) != nil && !hiddenMetricIDs.contains($0) }
        if let savedPins, pinnedMetricIDs != savedPins { persistPins() }
    }

    private func defaultPins(forCard cardID: String) -> [String] {
        registry.descriptors(for: cardID).filter(\.isPinnedByDefault).map(\.id)
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

    private func currentSnapshot() -> LayoutSnapshot {
        LayoutSnapshot(
            hiddenMetricIDs: hiddenMetricIDs,
            providerOrder: providerOrder,
            metricOrderByProvider: metricOrderByProvider,
            pinnedMetricIDs: pinnedMetricIDs
        )
    }

    func recordingUndoStep<T>(_ body: () -> T) -> T {
        guard !isApplyingUndo else { return body() }
        let before = currentSnapshot()
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        let result = body()
        if currentSnapshot() != before {
            undoSnapshots.append(before)
            if undoSnapshots.count > Self.maxUndoDepth { undoSnapshots.removeFirst() }
        }
        return result
    }

    @discardableResult
    func undo() -> Bool {
        guard let snapshot = undoSnapshots.popLast() else { return false }
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        restore(snapshot)
        return true
    }

    private func restore(_ snapshot: LayoutSnapshot) {
        hiddenMetricIDs = snapshot.hiddenMetricIDs
        providerOrder = snapshot.providerOrder
        metricOrderByProvider = snapshot.metricOrderByProvider
        pinnedMetricIDs = snapshot.pinnedMetricIDs
        persistHidden()
        persistProviderOrder()
        persistMetricOrder()
        persistPins()
    }

    static let maxPinsPerProvider = 2

    func isPinned(_ descriptorID: String) -> Bool { pinnedMetricIDs.contains(descriptorID) }

    func pinnedCount(forProvider providerID: String) -> Int {
        pinnedMetricIDs.count { registry.descriptor(id: $0)?.providerID == providerID }
    }

    func canPin(_ descriptorID: String) -> Bool {
        if pinnedMetricIDs.contains(descriptorID) { return true }
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
                guard pinnedMetricIDs.insert(descriptorID).inserted else { return }
                show(descriptorID)
            } else {
                guard pinnedMetricIDs.remove(descriptorID) != nil else { return }
            }
            persistPins()
        }
    }

    func togglePin(_ descriptorID: String) {
        setPinned(!isPinned(descriptorID), for: descriptorID)
    }

    func persistPins() {
        persistence.savePins(pinnedMetricIDs)
    }

    func show(_ descriptorID: String) {
        guard hiddenMetricIDs.remove(descriptorID) != nil else { return }
        persistHidden()
    }

    func hide(_ descriptorID: String) {
        guard registry.descriptor(id: descriptorID) != nil, hiddenMetricIDs.insert(descriptorID).inserted else { return }
        persistHidden()
        if pinnedMetricIDs.remove(descriptorID) != nil { persistPins() }
    }

    func persistHidden() {
        persistence.saveHidden(hiddenMetricIDs)
    }

    func persistProviderOrder() {
        persistence.saveProviderOrder(providerOrder)
    }

    func persistMetricOrder() {
        persistence.saveMetricOrder(metricOrderByProvider)
    }

    func metricOrder(for providerID: String) -> [String] {
        let valid = registry.descriptors(for: providerID).map(\.id)
        let saved = metricOrderByProvider[providerID] ?? []
        return LayoutOrdering.normalizedMetricIDs(saved, validIDs: valid)
    }
}

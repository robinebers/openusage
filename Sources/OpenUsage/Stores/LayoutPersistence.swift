import Foundation

enum LayoutPersistenceField: Hashable, CaseIterable {
    case placed
    case providerOrder
    case metricOrder
    case seededDefaults
    case pins
    case expandedMetrics
    case expandOnEnable
    case expandedProviders
}

/// The persistence-safe half of bootstrap's projection. It includes both current IDs and opaque IDs
/// from newer versions; the runtime half contains only IDs the current registry understands.
struct LayoutPersistedState {
    var placed: [PlacedWidget]
    var providerOrder: [String]
    var metricOrder: [String: [String]]
    var seededDefaults: [String]
    var pins: [String]
    var expandedMetrics: [String]
    var expandOnEnable: [String]
    var expandedProviders: [String]
}

/// The retained projection plus the subset bootstrap repaired or migrated and must write immediately.
struct LayoutPersistencePlan {
    let state: LayoutPersistedState
    let fieldsToWrite: Set<LayoutPersistenceField>
}

/// The saved half of `LayoutStore`. It owns the key names, encoding, and UserDefaults access so the
/// live store can focus on layout rules and user actions.
@MainActor
final class LayoutPersistence {
    /// Crash-safe dependency order for startup repairs. Section membership must precede placement so
    /// an interrupted new-default seed can finish correctly next launch; its seed marker is committed
    /// last so it never claims a widget was offered before that widget reached storage.
    static let startupWriteOrder: [LayoutPersistenceField] = [
        .providerOrder,
        .metricOrder,
        .pins,
        .expandedMetrics,
        .expandOnEnable,
        .expandedProviders,
        .placed,
        .seededDefaults
    ]

    /// A load keeps presence separate from a decoded value. That distinction lets startup preserve
    /// missing-key migration behavior while repairing a key that exists but has unreadable contents.
    struct Loaded<Value> {
        let value: Value?
        let isPresent: Bool

        fileprivate init(value: Value?, isPresent: Bool) {
            self.value = value
            self.isPresent = isPresent
        }
    }

    private let defaults: UserDefaults
    private let keys: Keys
    private var registry: WidgetRegistry?
    private var persistedState: LayoutPersistedState?

    init(defaults: UserDefaults, storageKey: String) {
        self.defaults = defaults
        self.keys = Keys(storageKey: storageKey)
    }

    func loadPlaced() -> Loaded<[PlacedWidget]> { decode([PlacedWidget].self, forKey: keys.placed) }
    func loadProviderOrder() -> Loaded<[String]> { decode([String].self, forKey: keys.providerOrder) }
    func loadMetricOrder() -> Loaded<[String: [String]]> {
        decode([String: [String]].self, forKey: keys.metricOrder)
    }
    func loadSeededDefaults() -> Loaded<[String]> { decode([String].self, forKey: keys.seededDefaults) }

    func loadPins() -> Loaded<[String]> { stringArray(forKey: keys.pins) }
    func loadExpandedMetrics() -> Loaded<[String]> { stringArray(forKey: keys.expandedMetrics) }
    func loadExpandOnEnable() -> Loaded<[String]> { stringArray(forKey: keys.expandOnEnable) }
    func loadExpandedProviders() -> Loaded<[String]> { stringArray(forKey: keys.expandedProviders) }
    func loadMenuBarStyle() -> MenuBarStyle { defaults.enumValue(forKey: keys.menuBarStyle, default: .text) }

    func savePlaced(_ value: [PlacedWidget]) {
        saveOrdered(
            value,
            at: \.placed,
            forKey: keys.placed,
            isKnown: { widget, registry in registry.descriptor(id: widget.descriptorID) != nil }
        )
    }

    func saveProviderOrder(_ value: [String]) {
        saveOrdered(
            value,
            at: \.providerOrder,
            forKey: keys.providerOrder,
            isKnown: { id, registry in registry.provider(id: id) != nil }
        )
    }

    func saveMetricOrder(_ value: [String: [String]]) {
        guard let registry, var state = persistedState else {
            encode(value, forKey: keys.metricOrder)
            return
        }

        var persisted = state.metricOrder
        for provider in registry.providers {
            let validIDs = Set(registry.descriptors(for: provider.id).map(\.id))
            persisted[provider.id] = Self.mergingOrder(
                value[provider.id] ?? [],
                into: state.metricOrder[provider.id] ?? [],
                isKnown: { validIDs.contains($0) }
            )
        }
        state.metricOrder = persisted
        persistedState = state
        encode(persisted, forKey: keys.metricOrder)
    }

    func saveSeededDefaults(_ value: Set<String>) {
        saveMembership(
            value,
            at: \.seededDefaults,
            isKnown: { id, registry in registry.descriptor(id: id) != nil },
            persist: { self.encode($0, forKey: self.keys.seededDefaults) }
        )
    }

    func savePins(_ value: Set<String>) {
        saveMembership(
            value,
            at: \.pins,
            isKnown: { id, registry in registry.descriptor(id: id) != nil },
            persist: { self.defaults.set($0, forKey: self.keys.pins) }
        )
    }

    func saveExpandedMetrics(_ value: Set<String>) {
        saveMembership(
            value,
            at: \.expandedMetrics,
            isKnown: { id, registry in registry.descriptor(id: id) != nil },
            persist: { self.defaults.set($0, forKey: self.keys.expandedMetrics) }
        )
    }

    func saveExpandOnEnable(_ value: Set<String>) {
        saveMembership(
            value,
            at: \.expandOnEnable,
            isKnown: { id, registry in registry.descriptor(id: id) != nil },
            persist: { self.defaults.set($0, forKey: self.keys.expandOnEnable) }
        )
    }

    func saveExpandedProviders(_ value: Set<String>) {
        saveMembership(
            value,
            at: \.expandedProviders,
            isKnown: { id, registry in registry.provider(id: id) != nil },
            persist: { self.defaults.set($0, forKey: self.keys.expandedProviders) }
        )
    }
    func saveMenuBarStyle(_ value: MenuBarStyle) {
        defaults.set(value.rawValue, forKey: keys.menuBarStyle)
    }

    /// Start retaining bootstrap's opaque projection, then perform only its required repair/migration
    /// writes. Every later save merges known runtime changes into this evolving state, so an older build
    /// cannot erase newer provider/metric settings merely because the user customized a known item.
    func activate(_ plan: LayoutPersistencePlan, registry: WidgetRegistry) {
        self.registry = registry
        self.persistedState = plan.state
        for field in Self.startupWriteOrder where plan.fieldsToWrite.contains(field) {
            write(field, from: plan.state)
        }
    }

    private func saveOrdered<Value: Encodable>(
        _ known: [Value],
        at keyPath: WritableKeyPath<LayoutPersistedState, [Value]>,
        forKey key: String,
        isKnown: (Value, WidgetRegistry) -> Bool
    ) {
        guard let registry, var state = persistedState else {
            encode(known, forKey: key)
            return
        }
        let persisted = Self.mergingOrder(
            known,
            into: state[keyPath: keyPath],
            isKnown: { isKnown($0, registry) }
        )
        state[keyPath: keyPath] = persisted
        persistedState = state
        encode(persisted, forKey: key)
    }

    private func saveMembership(
        _ known: Set<String>,
        at keyPath: WritableKeyPath<LayoutPersistedState, [String]>,
        isKnown: (String, WidgetRegistry) -> Bool,
        persist: ([String]) -> Void
    ) {
        guard let registry, var state = persistedState else {
            persist(known.sorted())
            return
        }
        let persisted = Self.mergingMembership(
            known,
            into: state[keyPath: keyPath],
            isKnown: { isKnown($0, registry) }
        )
        state[keyPath: keyPath] = persisted
        persistedState = state
        persist(persisted)
    }

    /// Replace current-registry slots with the runtime order, leaving opaque slots in place. If the
    /// known count changed, empty old slots disappear and additional known values append.
    private static func mergingOrder<Value>(
        _ known: [Value],
        into template: [Value],
        isKnown: (Value) -> Bool
    ) -> [Value] {
        var result: [Value] = []
        var knownIndex = known.startIndex
        for value in template {
            if isKnown(value) {
                guard knownIndex < known.endIndex else { continue }
                result.append(known[knownIndex])
                known.formIndex(after: &knownIndex)
            } else {
                result.append(value)
            }
        }
        result.append(contentsOf: known[knownIndex...])
        return result
    }

    /// Retain every opaque member, remove deselected known members, and append newly selected ones.
    private static func mergingMembership(
        _ known: Set<String>,
        into template: [String],
        isKnown: (String) -> Bool
    ) -> [String] {
        var remaining = known
        var result: [String] = []
        for id in template {
            if isKnown(id) {
                if remaining.remove(id) != nil { result.append(id) }
            } else {
                result.append(id)
            }
        }
        result.append(contentsOf: remaining.sorted())
        return result
    }

    private func write(_ field: LayoutPersistenceField, from state: LayoutPersistedState) {
        switch field {
        case .placed: encode(state.placed, forKey: keys.placed)
        case .providerOrder: encode(state.providerOrder, forKey: keys.providerOrder)
        case .metricOrder: encode(state.metricOrder, forKey: keys.metricOrder)
        case .seededDefaults: encode(state.seededDefaults, forKey: keys.seededDefaults)
        case .pins: defaults.set(state.pins, forKey: keys.pins)
        case .expandedMetrics: defaults.set(state.expandedMetrics, forKey: keys.expandedMetrics)
        case .expandOnEnable: defaults.set(state.expandOnEnable, forKey: keys.expandOnEnable)
        case .expandedProviders: defaults.set(state.expandedProviders, forKey: keys.expandedProviders)
        }
    }

    /// Fail loudly: a swallowed encode would silently lose a layout change with no signal.
    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            AppLog.warn(.config, "failed to persist layout '\(key)': \(error.localizedDescription)")
        }
    }

    /// Missing data is a normal first launch. Present-but-unreadable data is logged before startup uses
    /// its normal fallback, so a damaged saved layout is never silently hidden.
    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> Loaded<T> {
        guard defaults.object(forKey: key) != nil else {
            return Loaded(value: nil, isPresent: false)
        }
        guard let data = defaults.data(forKey: key) else {
            AppLog.warn(.config, "saved layout '\(key)' has an unexpected value type; reseeding default")
            return Loaded(value: nil, isPresent: true)
        }
        do {
            return Loaded(value: try JSONDecoder().decode(type, from: data), isPresent: true)
        } catch {
            AppLog.warn(.config, "saved layout '\(key)' failed to decode; reseeding default: \(error.localizedDescription)")
            return Loaded(value: nil, isPresent: true)
        }
    }

    /// `UserDefaults.stringArray(forKey:)` returns nil for both a missing key and a malformed value.
    /// Keep those cases distinct and log malformed storage so startup can repair it instead of silently
    /// treating corruption as a first launch.
    private func stringArray(forKey key: String) -> Loaded<[String]> {
        guard defaults.object(forKey: key) != nil else {
            return Loaded(value: nil, isPresent: false)
        }
        guard let value = defaults.stringArray(forKey: key) else {
            AppLog.warn(.config, "saved layout '\(key)' has an unexpected value type; reseeding default")
            return Loaded(value: nil, isPresent: true)
        }
        return Loaded(value: value, isPresent: true)
    }

    private struct Keys {
        let placed: String
        let providerOrder: String
        let metricOrder: String
        let seededDefaults: String
        let pins: String
        let expandedMetrics: String
        let expandOnEnable: String
        let expandedProviders: String
        let menuBarStyle: String

        init(storageKey: String) {
            placed = storageKey
            providerOrder = "\(storageKey).providerOrder"
            metricOrder = "\(storageKey).metricOrderByProvider"
            seededDefaults = "\(storageKey).seededDefaults"
            pins = "\(storageKey).menuBarPins"
            expandedMetrics = "\(storageKey).expandedMetrics"
            expandOnEnable = "\(storageKey).expandOnEnable"
            expandedProviders = "\(storageKey).expandedProviders"
            menuBarStyle = "\(storageKey).menuBarStyle"
        }
    }
}

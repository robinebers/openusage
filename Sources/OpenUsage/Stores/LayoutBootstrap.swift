import Foundation

/// The owner-approved defaults and the legacy baseline used when an existing user has no seed marker.
struct LayoutDefaultSet {
    let metricIDs: [String]
    let migrationBaselineMetricIDs: [String]
    let pinnedMetricIDs: [String]
    let expandedMetricIDs: [String]
}

/// Everything `LayoutStore` needs at the end of startup, plus the small set of migration writes that
/// should be made after its stored properties are initialized.
struct LayoutInitialState {
    let placed: [PlacedWidget]
    let providerOrder: [String]
    let metricOrderByProvider: [String: [String]]
    let pinnedMetricIDs: Set<String>
    let expandedMetricIDs: Set<String>
    let expandedProviderIDs: Set<String>
    let defaultExpandedOnEnableIDs: Set<String>
    let menuBarStyle: MenuBarStyle

    let shouldPersistPlaced: Bool
    let shouldPersistExpanded: Bool
    let shouldPersistExpandOnEnable: Bool
    let seededDefaultsToPersist: Set<String>?
}

/// Loads a layout for a fresh install or an existing user. This keeps startup/default-upgrade policy in
/// one place and leaves `LayoutStore` responsible for live actions after initialization.
@MainActor
enum LayoutBootstrap {
    static func load(
        registry: WidgetRegistry,
        persistence: LayoutPersistence,
        defaults: LayoutDefaultSet
    ) -> LayoutInitialState {
        let hasStoredLayout = persistence.hasStoredLayout
        let savedPlaced = persistence.loadPlaced()?.filter { registry.descriptor(id: $0.descriptorID) != nil }
        let startingPlaced = savedPlaced ?? defaults.metricIDs
            .filter { registry.descriptor(id: $0) != nil }
            .map { PlacedWidget(descriptorID: $0) }
        let seededResult = seedNewDefaultMetrics(
            into: startingPlaced,
            persistence: persistence,
            hasStoredLayout: hasStoredLayout,
            registry: registry,
            defaults: defaults
        )

        let providerOrder = persistence.loadProviderOrder() ?? registry.providers.map(\.id)
        let metricOrderByProvider = persistence.loadMetricOrder().map {
            LayoutOrdering.normalizedMetricOrder($0, registry: registry)
        } ?? LayoutOrdering.defaultMetricOrder(registry: registry)

        // An existing value — including an empty array from a user who unpinned everything — wins.
        let pinnedMetricIDs = Set(
            (persistence.loadPins() ?? defaults.pinnedMetricIDs)
                .filter { registry.descriptor(id: $0) != nil }
        )

        // Expanded membership is a fresh-install default only. Existing layouts that predate the feature
        // keep every familiar metric above the caret unless the user later moves one.
        var shouldPersistExpanded = false
        var expandedMetricIDs: Set<String>
        if let savedExpanded = persistence.loadExpandedMetrics() {
            expandedMetricIDs = Set(savedExpanded.filter { registry.descriptor(id: $0) != nil })
        } else if hasStoredLayout {
            expandedMetricIDs = []
        } else {
            expandedMetricIDs = Set(defaults.expandedMetricIDs.filter { registry.descriptor(id: $0) != nil })
            shouldPersistExpanded = true
        }

        let expandedProviderIDs = Set(
            (persistence.loadExpandedProviders() ?? []).filter { registry.provider(id: $0) != nil }
        )

        // A newly-shipped default metric is new to an existing user, so it may safely start below the
        // caret when that is its declared default. Metrics they already had are never silently hidden.
        let newlyExpanded = Set(seededResult.newlyPlaced)
            .intersection(defaults.expandedMetricIDs)
            .filter { registry.descriptor(id: $0) != nil }
        if !newlyExpanded.isSubset(of: expandedMetricIDs) {
            expandedMetricIDs.formUnion(newlyExpanded)
            shouldPersistExpanded = true
        }

        // Optional default-expanded metrics enter below the caret the first time they are enabled. The
        // saved queue wins so an explicit user move is not recreated on the next launch.
        let placedIDs = Set(seededResult.placed.map(\.descriptorID))
        let expandedNow = expandedMetricIDs
        let isExpandOnEnableCandidate: (String) -> Bool = { [registry] id in
            registry.descriptor(id: id) != nil && !expandedNow.contains(id) && !placedIDs.contains(id)
        }
        let savedOnEnable = persistence.loadExpandOnEnable()
        let defaultExpandedOnEnableIDs = Set(
            (savedOnEnable ?? defaults.expandedMetricIDs).filter(isExpandOnEnableCandidate)
        )

        return LayoutInitialState(
            placed: seededResult.placed,
            providerOrder: providerOrder,
            metricOrderByProvider: metricOrderByProvider,
            pinnedMetricIDs: pinnedMetricIDs,
            expandedMetricIDs: expandedMetricIDs,
            expandedProviderIDs: expandedProviderIDs,
            defaultExpandedOnEnableIDs: defaultExpandedOnEnableIDs,
            menuBarStyle: persistence.loadMenuBarStyle(),
            shouldPersistPlaced: seededResult.shouldPersistPlaced,
            shouldPersistExpanded: shouldPersistExpanded,
            shouldPersistExpandOnEnable: savedOnEnable == nil,
            seededDefaultsToPersist: seededResult.shouldPersistSeededDefaults
                ? seededResult.seededDefaults
                : nil
        )
    }

    private struct SeededDefaultsResult {
        let placed: [PlacedWidget]
        let seededDefaults: Set<String>
        let shouldPersistPlaced: Bool
        let shouldPersistSeededDefaults: Bool
        let newlyPlaced: [String]
    }

    private static func seedNewDefaultMetrics(
        into placed: [PlacedWidget],
        persistence: LayoutPersistence,
        hasStoredLayout: Bool,
        registry: WidgetRegistry,
        defaults: LayoutDefaultSet
    ) -> SeededDefaultsResult {
        let knownDefaults = LayoutOrdering.knownMetricIDs(defaults.metricIDs, registry: registry)
        let knownDefaultSet = Set(knownDefaults)
        let hasStoredSeededDefaults = persistence.hasStoredSeededDefaults

        let seededDefaults: Set<String>
        var shouldPersistSeededDefaults = false
        if let saved = persistence.loadSeededDefaults() {
            seededDefaults = Set(LayoutOrdering.knownMetricIDs(saved, registry: registry))
            shouldPersistSeededDefaults = seededDefaults != Set(saved)
        } else if hasStoredLayout {
            seededDefaults = Set(LayoutOrdering.knownMetricIDs(defaults.migrationBaselineMetricIDs, registry: registry))
            shouldPersistSeededDefaults = true
        } else {
            seededDefaults = knownDefaultSet
            shouldPersistSeededDefaults = true
        }

        let placedIDs = Set(placed.map(\.descriptorID))
        let toAdd = knownDefaults.filter { !seededDefaults.contains($0) && !placedIDs.contains($0) }
        let nextSeededDefaults = seededDefaults.union(knownDefaultSet)
        shouldPersistSeededDefaults = shouldPersistSeededDefaults
            || !hasStoredSeededDefaults
            || nextSeededDefaults != seededDefaults

        return SeededDefaultsResult(
            placed: placed + toAdd.map { PlacedWidget(descriptorID: $0) },
            seededDefaults: nextSeededDefaults,
            shouldPersistPlaced: !toAdd.isEmpty,
            shouldPersistSeededDefaults: shouldPersistSeededDefaults,
            newlyPlaced: toAdd
        )
    }
}

/// Pure ordering/default helpers shared by startup and live layout mutations.
enum LayoutOrdering {
    static func knownMetricIDs(_ ids: [String], registry: WidgetRegistry) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            guard registry.descriptor(id: id) != nil, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    static func defaultMetricOrder(registry: WidgetRegistry) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for provider in registry.providers {
            result[provider.id] = registry.descriptors(for: provider.id).map(\.id)
        }
        return result
    }

    static func normalizedMetricOrder(
        _ saved: [String: [String]],
        registry: WidgetRegistry
    ) -> [String: [String]] {
        var fallback = defaultMetricOrder(registry: registry)
        for provider in registry.providers {
            let valid = registry.descriptors(for: provider.id).map(\.id)
            if let savedIDs = saved[provider.id] {
                fallback[provider.id] = normalizedMetricIDs(savedIDs, validIDs: valid)
            }
        }
        return fallback
    }

    static func normalizedMetricIDs(_ saved: [String], validIDs: [String]) -> [String] {
        let validSet = Set(validIDs)
        var seen = Set<String>()
        var ordered = saved.filter { id in
            guard validSet.contains(id), !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
        ordered.append(contentsOf: validIDs.filter { !seen.contains($0) })
        return ordered
    }
}

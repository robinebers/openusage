import Foundation

/// The owner-approved defaults and the legacy baseline used when an existing user has no seed marker.
struct LayoutDefaultSet {
    let metricIDs: [String]
    let migrationBaselineMetricIDs: [String]
    let pinnedMetricIDs: [String]
    let expandedMetricIDs: [String]
}

/// Everything `LayoutStore` needs at the end of startup, plus the persistence-safe projection and
/// repair/migration writes activated after its stored properties are initialized.
struct LayoutInitialState {
    let placed: [PlacedWidget]
    let providerOrder: [String]
    let metricOrderByProvider: [String: [String]]
    let pinnedMetricIDs: Set<String>
    let expandedMetricIDs: Set<String>
    let expandedProviderIDs: Set<String>
    let defaultExpandedOnEnableIDs: Set<String>
    let menuBarStyle: MenuBarStyle

    let persistencePlan: LayoutPersistencePlan
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
        var fieldsToWrite = Set<LayoutPersistenceField>()

        let storedPlaced = persistence.loadPlaced()
        let hasStoredLayout = storedPlaced.isPresent
        let storedPlacedProjection = storedPlaced.value.map {
            LayoutOrdering.projectedPlacedWidgets($0, registry: registry)
        }
        let defaultPlaced = LayoutOrdering
            .knownMetricIDs(defaults.metricIDs, registry: registry)
            .map { PlacedWidget(descriptorID: $0) }
        let startingPlaced = storedPlacedProjection?.known ?? defaultPlaced
        let persistedStartingPlaced = storedPlacedProjection?.persisted ?? defaultPlaced
        let storedSeededDefaults = persistence.loadSeededDefaults()
        let seededResult = seedNewDefaultMetrics(
            into: startingPlaced,
            persistedPlaced: persistedStartingPlaced,
            storedSeededDefaults: storedSeededDefaults,
            hasStoredLayout: hasStoredLayout,
            registry: registry,
            defaults: defaults
        )
        if storedValueNeedsUpdate(storedPlaced, persisted: seededResult.persistedPlaced) {
            fieldsToWrite.insert(.placed)
        }
        if seededResult.shouldPersistSeededDefaults {
            fieldsToWrite.insert(.seededDefaults)
        }

        let validProviderIDs = registry.providers.map(\.id)
        let storedProviderOrder = persistence.loadProviderOrder()
        let providerOrderProjection = storedProviderOrder.value.map {
            LayoutOrdering.projectedIDs($0, validIDs: validProviderIDs)
        } ?? LayoutOrdering.IDProjection(known: validProviderIDs, persisted: validProviderIDs)
        if storedValueNeedsUpdate(storedProviderOrder, persisted: providerOrderProjection.persisted) {
            fieldsToWrite.insert(.providerOrder)
        }

        let storedMetricOrder = persistence.loadMetricOrder()
        let defaultMetricOrder = LayoutOrdering.defaultMetricOrder(registry: registry)
        let metricOrderProjection = storedMetricOrder.value.map {
            LayoutOrdering.projectedMetricOrder($0, registry: registry)
        } ?? LayoutOrdering.MetricOrderProjection(known: defaultMetricOrder, persisted: defaultMetricOrder)
        if storedValueNeedsUpdate(storedMetricOrder, persisted: metricOrderProjection.persisted) {
            fieldsToWrite.insert(.metricOrder)
        }

        // An existing value — including an empty array from a user who unpinned everything — wins.
        let storedPins = persistence.loadPins()
        let pinsProjection = projectedMembership(
            storedPins.value ?? defaults.pinnedMetricIDs,
            isKnown: { registry.descriptor(id: $0) != nil }
        )
        if storedValueNeedsUpdate(storedPins, persisted: pinsProjection.persisted) {
            fieldsToWrite.insert(.pins)
        }

        // Expanded membership is a fresh-install default only. Existing layouts that predate the feature
        // keep every familiar metric above the caret unless the user later moves one.
        let storedExpanded = persistence.loadExpandedMetrics()
        let expandedSource = storedExpanded.value ?? (hasStoredLayout ? [] : defaults.expandedMetricIDs)
        var expandedProjection = projectedMembership(
            expandedSource,
            isKnown: { registry.descriptor(id: $0) != nil }
        )
        if (!storedExpanded.isPresent && !hasStoredLayout)
            || storedValueNeedsUpdate(storedExpanded, persisted: expandedProjection.persisted) {
            fieldsToWrite.insert(.expandedMetrics)
        }

        let storedExpandedProviders = persistence.loadExpandedProviders()
        let expandedProvidersProjection = projectedMembership(
            storedExpandedProviders.value ?? [],
            isKnown: { registry.provider(id: $0) != nil }
        )
        if storedValueNeedsUpdate(storedExpandedProviders, persisted: expandedProvidersProjection.persisted) {
            fieldsToWrite.insert(.expandedProviders)
        }

        // A newly-shipped default metric is new to an existing user, so it may safely start below the
        // caret when that is its declared default. Metrics they already had are never silently hidden.
        let newlyExpanded = Set(seededResult.newlyPlaced)
            .intersection(defaults.expandedMetricIDs)
            .filter { registry.descriptor(id: $0) != nil }
        for id in newlyExpanded where expandedProjection.known.insert(id).inserted {
            expandedProjection.persisted.append(id)
            fieldsToWrite.insert(.expandedMetrics)
        }

        // Optional default-expanded metrics enter below the caret the first time they are enabled. The
        // saved queue wins so an explicit user move is not recreated on the next launch.
        let placedIDs = Set(seededResult.placed.map(\.descriptorID))
        let expandedNow = expandedProjection.known
        let isExpandOnEnableCandidate: (String) -> Bool = { [registry] id in
            registry.descriptor(id: id) != nil && !expandedNow.contains(id) && !placedIDs.contains(id)
        }
        let storedOnEnable = persistence.loadExpandOnEnable()
        let onEnableProjection = projectedMembership(
            storedOnEnable.value ?? defaults.expandedMetricIDs,
            isKnown: { registry.descriptor(id: $0) != nil },
            keepKnown: isExpandOnEnableCandidate
        )
        if !storedOnEnable.isPresent
            || storedValueNeedsUpdate(storedOnEnable, persisted: onEnableProjection.persisted) {
            fieldsToWrite.insert(.expandOnEnable)
        }

        return LayoutInitialState(
            placed: seededResult.placed,
            providerOrder: providerOrderProjection.known,
            metricOrderByProvider: metricOrderProjection.known,
            pinnedMetricIDs: pinsProjection.known,
            expandedMetricIDs: expandedProjection.known,
            expandedProviderIDs: expandedProvidersProjection.known,
            defaultExpandedOnEnableIDs: onEnableProjection.known,
            menuBarStyle: persistence.loadMenuBarStyle(),
            persistencePlan: LayoutPersistencePlan(
                state: LayoutPersistedState(
                    placed: seededResult.persistedPlaced,
                    providerOrder: providerOrderProjection.persisted,
                    metricOrder: metricOrderProjection.persisted,
                    seededDefaults: seededResult.persistedSeededDefaults,
                    pins: pinsProjection.persisted,
                    expandedMetrics: expandedProjection.persisted,
                    expandOnEnable: onEnableProjection.persisted,
                    expandedProviders: expandedProvidersProjection.persisted
                ),
                fieldsToWrite: fieldsToWrite
            )
        )
    }

    private struct SeededDefaultsResult {
        let placed: [PlacedWidget]
        let persistedPlaced: [PlacedWidget]
        let persistedSeededDefaults: [String]
        let shouldPersistSeededDefaults: Bool
        let newlyPlaced: [String]
    }

    private static func seedNewDefaultMetrics(
        into placed: [PlacedWidget],
        persistedPlaced: [PlacedWidget],
        storedSeededDefaults: LayoutPersistence.Loaded<[String]>,
        hasStoredLayout: Bool,
        registry: WidgetRegistry,
        defaults: LayoutDefaultSet
    ) -> SeededDefaultsResult {
        let knownDefaults = LayoutOrdering.knownMetricIDs(defaults.metricIDs, registry: registry)
        let knownDefaultSet = Set(knownDefaults)

        var seededProjection: MembershipProjection
        var shouldPersistSeededDefaults = false
        if let saved = storedSeededDefaults.value {
            seededProjection = projectedMembership(
                saved,
                isKnown: { registry.descriptor(id: $0) != nil }
            )
            shouldPersistSeededDefaults = saved != seededProjection.persisted
        } else if hasStoredLayout {
            let baseline = LayoutOrdering.knownMetricIDs(
                defaults.migrationBaselineMetricIDs,
                registry: registry
            )
            seededProjection = MembershipProjection(known: Set(baseline), persisted: baseline)
            shouldPersistSeededDefaults = true
        } else {
            seededProjection = MembershipProjection(known: knownDefaultSet, persisted: knownDefaults)
            shouldPersistSeededDefaults = true
        }

        let placedIDs = Set(placed.map(\.descriptorID))
        let toAdd = knownDefaults.filter {
            !seededProjection.known.contains($0) && !placedIDs.contains($0)
        }

        var nextPlaced = placed
        var nextPersistedPlaced = persistedPlaced
        var usedWidgetIDs = Set(persistedPlaced.map(\.id))
        for descriptorID in toAdd {
            var widget = PlacedWidget(descriptorID: descriptorID)
            while !usedWidgetIDs.insert(widget.id).inserted {
                widget.id = UUID()
            }
            nextPlaced.append(widget)
            nextPersistedPlaced.append(widget)
        }

        for id in knownDefaults where seededProjection.known.insert(id).inserted {
            seededProjection.persisted.append(id)
            shouldPersistSeededDefaults = true
        }

        return SeededDefaultsResult(
            placed: nextPlaced,
            persistedPlaced: nextPersistedPlaced,
            persistedSeededDefaults: seededProjection.persisted,
            shouldPersistSeededDefaults: shouldPersistSeededDefaults,
            newlyPlaced: toAdd
        )
    }

    private struct MembershipProjection {
        var known: Set<String>
        var persisted: [String]
    }

    /// Keep unknown IDs byte-for-byte at their original array positions for downgrade safety while
    /// filtering them out of the current runtime. Known IDs can be deduplicated or rejected by a
    /// field-specific invariant without making assumptions about a newer schema's opaque values.
    private static func projectedMembership(
        _ ids: [String],
        isKnown: (String) -> Bool,
        keepKnown: (String) -> Bool = { _ in true }
    ) -> MembershipProjection {
        var known = Set<String>()
        var persisted: [String] = []
        for id in ids {
            guard isKnown(id) else {
                persisted.append(id)
                continue
            }
            guard keepKnown(id), known.insert(id).inserted else { continue }
            persisted.append(id)
        }
        return MembershipProjection(known: known, persisted: persisted)
    }

    /// A missing key intentionally keeps its migration/default behavior. A present key is updated when
    /// decoding failed or canonicalization changed its persistence-safe (opaque-ID-preserving) value.
    private static func storedValueNeedsUpdate<Value: Equatable>(
        _ stored: LayoutPersistence.Loaded<Value>,
        persisted: Value
    ) -> Bool {
        guard stored.isPresent else { return false }
        guard let value = stored.value else { return true }
        return value != persisted
    }
}

/// Pure ordering/default helpers shared by startup and live layout mutations.
enum LayoutOrdering {
    struct IDProjection {
        let known: [String]
        let persisted: [String]
    }

    struct PlacedProjection {
        let known: [PlacedWidget]
        let persisted: [PlacedWidget]
    }

    struct MetricOrderProjection {
        let known: [String: [String]]
        let persisted: [String: [String]]
    }

    /// Project placed widgets into the current registry while retaining opaque future widgets in the
    /// persistence copy. Known descriptor duplicates are removed. Stable UUID collisions across
    /// distinct known descriptors keep the first identity and assign a fresh one to later widgets;
    /// collisions with opaque widgets re-key the known side so the newer identity stays untouched.
    static func projectedPlacedWidgets(
        _ widgets: [PlacedWidget],
        registry: WidgetRegistry
    ) -> PlacedProjection {
        var known: [PlacedWidget] = []
        var persisted: [PlacedWidget] = []
        var knownDescriptorIDs = Set<String>()
        // An older build may repair its own widgets, but must not re-key an opaque widget from a newer
        // version. Reserve every opaque identity up front, even when its entry comes later in the array.
        var usedWidgetIDs = Set(
            widgets.lazy
                .filter { registry.descriptor(id: $0.descriptorID) == nil }
                .map(\.id)
        )

        for widget in widgets {
            guard registry.descriptor(id: widget.descriptorID) != nil else {
                persisted.append(widget)
                continue
            }
            guard knownDescriptorIDs.insert(widget.descriptorID).inserted else { continue }

            var canonical = widget
            while !usedWidgetIDs.insert(canonical.id).inserted {
                canonical.id = UUID()
            }
            known.append(canonical)
            persisted.append(canonical)
        }
        return PlacedProjection(known: known, persisted: persisted)
    }

    static func knownMetricIDs(_ ids: [String], registry: WidgetRegistry) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            registry.descriptor(id: id) != nil && seen.insert(id).inserted
        }
    }

    static func defaultMetricOrder(registry: WidgetRegistry) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for provider in registry.providers {
            result[provider.id] = registry.descriptors(for: provider.id).map(\.id)
        }
        return result
    }

    static func projectedMetricOrder(
        _ saved: [String: [String]],
        registry: WidgetRegistry
    ) -> MetricOrderProjection {
        var known = defaultMetricOrder(registry: registry)
        var persisted = saved
        for provider in registry.providers {
            let valid = registry.descriptors(for: provider.id).map(\.id)
            let projection = saved[provider.id].map {
                projectedIDs($0, validIDs: valid)
            } ?? IDProjection(known: valid, persisted: valid)
            known[provider.id] = projection.known
            persisted[provider.id] = projection.persisted
        }
        return MetricOrderProjection(known: known, persisted: persisted)
    }

    /// Keep known IDs in saved order, deduplicate them, and append newly-known IDs in registry order.
    /// Unknown IDs remain in the persistence projection at their original positions for downgrade
    /// safety, but are absent from the runtime projection.
    static func projectedIDs(_ saved: [String], validIDs: [String]) -> IDProjection {
        let validSet = Set(validIDs)
        var seenKnown = Set<String>()
        var known: [String] = []
        var persisted: [String] = []

        for id in saved {
            guard validSet.contains(id) else {
                persisted.append(id)
                continue
            }
            guard seenKnown.insert(id).inserted else { continue }
            known.append(id)
            persisted.append(id)
        }

        let missing = validIDs.filter { seenKnown.insert($0).inserted }
        known.append(contentsOf: missing)
        persisted.append(contentsOf: missing)
        return IDProjection(known: known, persisted: persisted)
    }
}

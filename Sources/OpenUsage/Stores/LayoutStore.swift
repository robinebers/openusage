import SwiftUI
import Observation

/// Mutable layout: which widgets are enabled, provider order, and each provider's metric order.
/// `placed` is the enabled set (with stable widget ids); `metricOrderByProvider` is the user's custom order.
@MainActor
@Observable
final class LayoutStore {
    private(set) var placed: [PlacedWidget]

    /// In-popover navigation (screen, Customize master/detail, screen-switch slide). Its own store so
    /// screen routing isn't tangled with layout state; the `screen`/`isEditing`/`customizeProviderID`/
    /// `screenSlide*` surface below forwards to it, so existing call sites are unchanged. The forwarding
    /// surface remains the only spelling used by the app — two live paths to the same state invite drift.
    let navigation = PopoverNavigationStore()

    /// Placed widget being drag-reordered (transient). `PlacedWidget.id`, never persisted.
    var draggingID: UUID?
    /// Persisted provider display order (provider IDs). Drives both the dashboard groups and the
    /// Customize sections, so the user can drag whole providers into the order they want.
    private(set) var providerOrder: [String]
    /// Persisted metric order within each provider. Toggle switches do not mutate this, so turning a metric on
    /// or off never makes rows jump around in Customize.
    private(set) var metricOrderByProvider: [String: [String]]

    /// Descriptor ids pinned to the menu bar. Membership only — display order is derived from the
    /// provider + metric order above, so pins follow the same sequence shown in Customize. Capped via
    /// `canPin` to at most `maxPinsPerProvider` per provider (the strip stacks a provider's values in pairs).
    private(set) var pinnedMetricIDs: Set<String>

    /// Descriptor ids that sit below the per-provider "Shown on expand" divider: the dashboard hides
    /// them behind a caret until the user taps it, and Customize lists them under the divider.
    /// Membership only — the sequence within each section follows the provider's metric order, like
    /// pins. A metric keeps its membership while disabled, so re-enabling restores its section.
    private(set) var expandedMetricIDs: Set<String>

    /// Provider IDs whose dashboard cards are currently opened with their expanded metrics visible.
    /// Unlike hover and drag state, this is a user preference: if someone likes Codex open, it should
    /// stay open across popover closes and app restarts.
    private(set) var expandedProviderIDs: Set<String>

    /// The three transient popover pills, each an auto-clearing `TransientNotice` (was three copy-pasted
    /// value+trigger+clearTask machines). The public `pinLimitNotice`/`shareConfirmation`/
    /// `customizationNotice` surface below forwards to these, so call sites are unchanged.
    let pinNotice = TransientNotice<String?>(clearedValue: nil, timeout: .seconds(3))
    let shareNotice = TransientNotice<Bool>(clearedValue: false, timeout: .seconds(2.5))
    let customizeNotice = TransientNotice<CustomizationNoticeContent?>(clearedValue: nil, timeout: .seconds(2.5))

    /// Bounded, app-wide undo stack for layout customization (remove/add a metric, reorder metrics or
    /// providers, pin/unpin, move across the expand caret). UI-only state (not persisted): undo is a
    /// within-session affordance, so a relaunch starts fresh. Each entry is a pre-change `LayoutSnapshot`;
    /// `undo()` pops and restores one.
    private var undoHistory = LayoutUndoHistory()
    /// True while `undo()` is replaying a snapshot, so the mutations it triggers don't push themselves
    /// back onto the stack (an undo must not be recorded as a new, separately-undoable action).
    private var isApplyingUndo = false

    /// Menu-bar display style (Text strip vs. compact Bars). Persisted; defaults to `.text`.
    var menuBarStyle: MenuBarStyle {
        didSet { persistence.saveMenuBarStyle(menuBarStyle) }
    }

    let registry: WidgetRegistry
    private let persistence: LayoutPersistence
    private let defaultMetricIDs: [String]
    private let defaultPinnedMetricIDs: [String]
    private let defaultExpandedMetricIDs: [String]
    private var defaultExpandedOnEnableIDs: Set<String>
    let isProviderEnabled: @MainActor (String) -> Bool

    init(
        registry: WidgetRegistry,
        defaults: UserDefaults = .standard,
        storageKey: String = "openusage.layout.v1",
        defaultMetricIDs: [String] = DefaultLayout.metricIDs,
        migrationBaselineMetricIDs: [String] = DefaultLayout.migrationBaselineMetricIDs,
        defaultPinnedMetricIDs: [String] = DefaultLayout.pinnedMetricIDs,
        defaultExpandedMetricIDs: [String] = DefaultLayout.expandedMetricIDs,
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true }
    ) {
        self.registry = registry
        let persistence = LayoutPersistence(defaults: defaults, storageKey: storageKey)
        self.persistence = persistence
        self.defaultMetricIDs = defaultMetricIDs
        self.defaultPinnedMetricIDs = defaultPinnedMetricIDs
        self.defaultExpandedMetricIDs = defaultExpandedMetricIDs
        self.isProviderEnabled = isProviderEnabled

        let initial = LayoutBootstrap.load(
            registry: registry,
            persistence: persistence,
            defaults: LayoutDefaultSet(
                metricIDs: defaultMetricIDs,
                migrationBaselineMetricIDs: migrationBaselineMetricIDs,
                pinnedMetricIDs: defaultPinnedMetricIDs,
                expandedMetricIDs: defaultExpandedMetricIDs
            )
        )
        placed = initial.placed
        providerOrder = initial.providerOrder
        metricOrderByProvider = initial.metricOrderByProvider
        pinnedMetricIDs = initial.pinnedMetricIDs
        expandedMetricIDs = initial.expandedMetricIDs
        expandedProviderIDs = initial.expandedProviderIDs
        defaultExpandedOnEnableIDs = initial.defaultExpandedOnEnableIDs
        menuBarStyle = initial.menuBarStyle

        syncPlacedOrder(persistChanges: false)
        persistence.activate(initial.persistencePlan, registry: registry)
    }

    // MARK: - Customize mutations

    /// Toggle a metric on (add to the placed list) or off (remove it). The single seam the Customize
    /// switches drive, so on/off goes through the same add/remove path the rest of the app uses.
    func setMetricEnabled(_ descriptorID: String, _ enabled: Bool) {
        recordingUndoStep {
            if enabled {
                if defaultExpandedOnEnableIDs.remove(descriptorID) != nil {
                    expandedMetricIDs.insert(descriptorID)
                    persistExpanded()
                    persistExpandOnEnable()
                }
                add(descriptorID)
            } else if let widget = placed.first(where: { $0.descriptorID == descriptorID }) {
                remove(widget.id)
            }
        }
    }

    // MARK: - Undo (#603)

    /// Whether there's at least one customization step to walk back. Drives the Customize Undo button's
    /// presence and the app-wide ⌘Z handler's no-op guard.
    var canUndo: Bool { undoHistory.canUndo }

    /// A snapshot of the current undoable layout state.
    private func currentSnapshot() -> LayoutSnapshot {
        LayoutSnapshot(
            placed: placed,
            providerOrder: providerOrder,
            metricOrderByProvider: metricOrderByProvider,
            pinnedMetricIDs: pinnedMetricIDs,
            expandedMetricIDs: expandedMetricIDs,
            defaultExpandedOnEnableIDs: defaultExpandedOnEnableIDs
        )
    }

    /// Run a user-facing layout mutation, recording one undo step for it. Snapshots state before the
    /// change and pushes that snapshot only if the change actually altered the layout — so a no-op
    /// action (toggling an already-on metric, dropping a row back where it started) doesn't pollute the
    /// stack with empty steps. Re-entrant calls (a mutation built from smaller ones) and undo replay
    /// itself coalesce into the single outer step via `isApplyingUndo`.
    private func recordingUndoStep<T>(_ body: () -> T) -> T {
        // Already inside an undoable scope (or replaying an undo): just run — the outer scope owns the
        // single recorded step, and undo must never record itself.
        guard !isApplyingUndo else { return body() }
        let before = currentSnapshot()
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        let result = body()
        if currentSnapshot() != before {
            undoHistory.record(before)
        }
        return result
    }

    /// Walk back the most recent customization step, restoring the layout to its state just before that
    /// action. A no-op (returns `false`) when there's nothing to undo. Repeated calls step further back.
    /// Available app-wide (dashboard context menus and Customize alike), not just on one screen.
    @discardableResult
    func undo() -> Bool {
        guard let snapshot = undoHistory.popLast() else { return false }
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        restore(snapshot)
        return true
    }

    /// Restore every undoable field from a snapshot and persist the result. Called by `undo()`.
    /// Provider card expand/collapse (`expandedProviderIDs`) is deliberately excluded: it's transient
    /// view state, not a layout edit, so undo must not rewind caret toggles done between steps.
    private func restore(_ snapshot: LayoutSnapshot) {
        cancelDrag()
        placed = snapshot.placed
        providerOrder = snapshot.providerOrder
        metricOrderByProvider = snapshot.metricOrderByProvider
        pinnedMetricIDs = snapshot.pinnedMetricIDs
        expandedMetricIDs = snapshot.expandedMetricIDs
        defaultExpandedOnEnableIDs = snapshot.defaultExpandedOnEnableIDs
        persist()
        persistProviderOrder()
        persistMetricOrder()
        persistPins()
        persistExpanded()
        persistExpandOnEnable()
    }

    /// Reorder whole providers when `dragged`'s header is dropped onto `target`'s. Works on the currently
    /// shown (enabled) provider order; disabled providers keep their relative tail position.
    /// Returns whether the order actually changed — the drag gestures key haptics off it.
    @discardableResult
    func reorderProvider(dragged: String, target: String) -> Bool {
        recordingUndoStep {
            let shown = customizeGroups.map(\.provider.id)
            guard let next = Self.reordered(shown, dragged: dragged, target: target) else { return false }
            let rest = providerOrder.filter { !next.contains($0) }
            providerOrder = next + rest
            persistProviderOrder()
            syncPlacedOrder()
            return true
        }
    }

    /// Reorder metrics within one provider when `dragged` is dropped onto `target` (both descriptor ids of
    /// that provider). Operates on the provider's full metric order so disabled metrics keep their place too.
    ///
    /// Dropping onto a row in the *other* section moves `dragged` across the "Shown on expand" divider:
    /// its expanded membership follows the target's, so dragging a metric under an expanded one tucks it
    /// away too (and vice versa). The stored order is rebuilt as always-shown rows then expanded rows, so
    /// it always matches the partitioned layout the UI draws. Returns whether anything actually changed —
    /// the drag gestures key haptics off it.
    @discardableResult
    func reorderMetric(dragged: String, target: String, in providerID: String) -> Bool {
        recordingUndoStep { reorderMetricImpl(dragged: dragged, target: target, in: providerID) }
    }

    private func reorderMetricImpl(dragged: String, target: String, in providerID: String) -> Bool {
        guard dragged != target else { return false }
        let ordered = metricOrder(for: providerID)
        guard ordered.contains(dragged), ordered.contains(target) else { return false }

        var expanded = expandedMetricIDs
        let membershipChanged = expanded.contains(dragged) != expanded.contains(target)
        if expanded.contains(target) {
            expanded.insert(dragged)
        } else {
            expanded.remove(dragged)
        }

        // Landing a metric in the always-shown section is an explicit placement, so it consumes its
        // expand-on-enable default — otherwise enabling it later would tuck it back below the caret,
        // overriding this drag.
        let consumedExpandOnEnable = !expanded.contains(dragged)
            && defaultExpandedOnEnableIDs.remove(dragged) != nil

        // Lay the provider out the way it renders — always-shown rows, then expanded rows — keeping each
        // section in its current order, then drop `dragged` next to `target` within that combined sequence.
        let partitioned = ordered.filter { !expanded.contains($0) } + ordered.filter { expanded.contains($0) }
        guard let next = Self.reordered(partitioned, dragged: dragged, target: target) else {
            guard membershipChanged || consumedExpandOnEnable else { return false }
            metricOrderByProvider[providerID] = partitioned
            expandedMetricIDs = expanded
            persistMetricOrder()
            persistExpanded()
            if consumedExpandOnEnable { persistExpandOnEnable() }
            syncPlacedOrder()
            return true
        }
        metricOrderByProvider[providerID] = next
        expandedMetricIDs = expanded
        persistMetricOrder()
        if membershipChanged { persistExpanded() }
        if consumedExpandOnEnable { persistExpandOnEnable() }
        syncPlacedOrder()
        return true
    }

    /// Apply a provider metric order that includes one visual divider sentinel. Metrics before the
    /// sentinel become always-shown; metrics after it become shown-on-expand. This is the clean drag
    /// model for Customize: the divider participates in target geometry like a row, but persistence
    /// remains metric-only.
    @discardableResult
    func applyMetricDividerOrder(_ orderedIDsWithDivider: [String], dragged: String, dividerID: String, in providerID: String) -> Bool {
        recordingUndoStep {
            applyMetricDividerOrderImpl(orderedIDsWithDivider, dragged: dragged, dividerID: dividerID, in: providerID)
        }
    }

    private func applyMetricDividerOrderImpl(_ orderedIDsWithDivider: [String], dragged: String, dividerID: String, in providerID: String) -> Bool {
        let validIDs = metricOrder(for: providerID)
        let validSet = Set(validIDs)
        guard orderedIDsWithDivider.contains(dividerID) else { return false }

        var seen = Set<String>()
        var alwaysShown: [String] = []
        var expanded: [String] = []
        var isBelowDivider = false

        for id in orderedIDsWithDivider {
            if id == dividerID {
                isBelowDivider = true
                continue
            }
            guard validSet.contains(id), seen.insert(id).inserted else { continue }
            if isBelowDivider {
                expanded.append(id)
            } else {
                alwaysShown.append(id)
            }
        }

        // Dashboard rows only render enabled metrics. Merge disabled rows back into their previous
        // sections so a dashboard drag does not push hidden Customize rows to the end.
        let desiredAlwaysShown = Set(alwaysShown)
        let desiredExpanded = Set(expanded)
        let previousAlwaysShown = validIDs.filter { !expandedMetricIDs.contains($0) && !desiredExpanded.contains($0) }
        let previousExpanded = validIDs.filter { expandedMetricIDs.contains($0) && !desiredAlwaysShown.contains($0) }
        alwaysShown = Self.mergingMissingMetrics(into: alwaysShown, previous: previousAlwaysShown)
        expanded = Self.mergingMissingMetrics(into: expanded, previous: previousExpanded)

        let nextOrder = alwaysShown + expanded
        let providerExpanded = Set(expanded)
        let providerIDs = Set(validIDs)
        let nextExpanded = expandedMetricIDs.subtracting(providerIDs).union(providerExpanded)
        // Only the dragged metric's expand-on-enable entry is consumed — an explicit placement.
        // Clearing every metric in the list (the old `subtracting(seen)`) also cleared disabled
        // optional metrics that `metricOrderWithDivider` includes by default but the user never moved,
        // so they lost their below-caret default. Matches `reorderMetric`, which consumes only the
        // dragged id.
        var nextDefaultExpandedOnEnableIDs = defaultExpandedOnEnableIDs
        let consumedExpandOnEnable = nextDefaultExpandedOnEnableIDs.remove(dragged) != nil
        guard metricOrderByProvider[providerID] != nextOrder || expandedMetricIDs != nextExpanded || consumedExpandOnEnable else {
            return false
        }

        metricOrderByProvider[providerID] = nextOrder
        expandedMetricIDs = nextExpanded
        defaultExpandedOnEnableIDs = nextDefaultExpandedOnEnableIDs
        persistMetricOrder()
        persistExpanded()
        if consumedExpandOnEnable { persistExpandOnEnable() }
        syncPlacedOrder()
        return true
    }

    // MARK: - Menu bar pin mutations

    /// Pin or unpin a metric for the menu bar. Pinning is a no-op when it would exceed a cap, so callers
    /// can gate the control on `canPin` and trust this never over-pins. Undoable like the other layout
    /// actions — the no-op guards mean a denied or redundant pin records no step.
    func setPinned(_ pinned: Bool, for descriptorID: String) {
        recordingUndoStep {
            if pinned {
                guard canPin(descriptorID), registry.descriptor(id: descriptorID) != nil else { return }
                guard pinnedMetricIDs.insert(descriptorID).inserted else { return }
            } else {
                guard pinnedMetricIDs.remove(descriptorID) != nil else { return }
            }
            persistPins()
        }
    }

    private func persistPins() {
        persistence.savePins(pinnedMetricIDs)
    }

    private func persistExpanded() {
        persistence.saveExpandedMetrics(expandedMetricIDs)
    }

    private func persistExpandOnEnable() {
        persistence.saveExpandOnEnable(defaultExpandedOnEnableIDs)
    }

    private func persistExpandedProviders() {
        persistence.saveExpandedProviders(expandedProviderIDs)
    }

    @discardableResult
    func setProviderExpanded(_ expanded: Bool, for providerID: String) -> Bool {
        guard registry.provider(id: providerID) != nil else { return false }
        guard expandedProviderIDs.contains(providerID) != expanded else { return false }
        if expanded {
            expandedProviderIDs.insert(providerID)
        } else {
            expandedProviderIDs.remove(providerID)
        }
        persistExpandedProviders()
        return true
    }

    // MARK: - Mutations

    func add(_ descriptorID: String) {
        guard registry.descriptor(id: descriptorID) != nil else { return }
        guard !placed.contains(where: { $0.descriptorID == descriptorID }) else { return }
        cancelDrag()
        placed.append(PlacedWidget(descriptorID: descriptorID))
        syncPlacedOrder()
    }

    func remove(_ id: UUID) {
        guard let index = placed.firstIndex(where: { $0.id == id }) else { return }
        cancelDrag()
        placed.remove(at: index)
        persist()
    }

    func resetToDefault() {
        cancelDrag()
        // Reset is its own deliberate action, not an undoable layout edit; the recorded snapshots
        // describe the pre-reset layout, so the undo stack is dropped wholesale here.
        undoHistory.clear()
        placed = defaultMetricIDs
            .filter { registry.descriptor(id: $0) != nil }
            .map { PlacedWidget(descriptorID: $0) }
        providerOrder = registry.providers.map(\.id)
        persistProviderOrder()
        metricOrderByProvider = LayoutOrdering.defaultMetricOrder(registry: registry)
        persistMetricOrder()
        pinnedMetricIDs = Set(defaultPinnedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        persistPins()
        expandedMetricIDs = Set(defaultExpandedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        defaultExpandedOnEnableIDs = []
        persistExpanded()
        persistExpandOnEnable()
        expandedProviderIDs = []
        persistExpandedProviders()
        persistSeededDefaults(Set(LayoutOrdering.knownMetricIDs(defaultMetricIDs, registry: registry)))
        persist()
    }

    /// Reset a single provider's customization to default — its enabled metrics, metric order, pins,
    /// and expanded (caret) membership — while leaving every other provider, and the overall provider
    /// order, untouched. The per-provider counterpart to `resetToDefault` ("Reset all providers"): same
    /// per-provider effect, scoped to one `providerID` instead of the whole layout. No-op for an
    /// unknown provider.
    func resetProvider(_ providerID: String) {
        guard registry.provider(id: providerID) != nil else { return }
        cancelDrag()
        // A reset is its own action, not an undoable edit. Snapshots are whole-layout, so there's no
        // per-provider trim to do — clear the stack so undo can't restore into the pre-reset layout.
        undoHistory.clear()

        // This provider's descriptor universe — the membership sets below are all scoped to it.
        let owned = Set(registry.descriptors(for: providerID).map(\.id))
        func defaults(_ ids: [String]) -> [String] {
            ids.filter { owned.contains($0) && registry.descriptor(id: $0) != nil }
        }

        // Enabled metrics: drop this provider's placed widgets, re-seed its default-on set. Other
        // providers' widgets keep their identity and position; `syncPlacedOrder` re-sorts the whole
        // list by provider + metric order at the end.
        placed = placed.filter { !owned.contains($0.descriptorID) }
            + defaults(defaultMetricIDs).map { PlacedWidget(descriptorID: $0) }

        // Metric order back to registry order for this provider only.
        metricOrderByProvider[providerID] = registry.descriptors(for: providerID).map(\.id)
        persistMetricOrder()

        // Pins, expanded membership, and the default-expanded-on-enable carry: swap this provider's
        // entries for its defaults, leaving the rest of each set intact.
        pinnedMetricIDs.subtract(owned)
        pinnedMetricIDs.formUnion(defaults(defaultPinnedMetricIDs))
        persistPins()

        expandedMetricIDs.subtract(owned)
        expandedMetricIDs.formUnion(defaults(defaultExpandedMetricIDs))
        defaultExpandedOnEnableIDs.subtract(owned)
        persistExpanded()
        persistExpandOnEnable()

        // Default is a collapsed card.
        if expandedProviderIDs.remove(providerID) != nil {
            persistExpandedProviders()
        }

        syncPlacedOrder() // persists `placed`
    }

    private func persist() {
        persistence.savePlaced(placed)
    }

    private func persistProviderOrder() {
        persistence.saveProviderOrder(providerOrder)
    }

    private func persistMetricOrder() {
        persistence.saveMetricOrder(metricOrderByProvider)
    }

    private func persistSeededDefaults(_ ids: Set<String>) {
        persistence.saveSeededDefaults(ids)
    }

    private func syncPlacedOrder(persistChanges: Bool = true) {
        // Startup canonicalization plus private setters guarantee one known widget per descriptor.
        // Trust that invariant here: silently appending duplicate or unregistered runtime leftovers
        // would hide an internal bug. Opaque future IDs live only in the persistence layer's retained
        // projection and never leak into this runtime collection.
        let byDescriptor = Dictionary(uniqueKeysWithValues: placed.map { ($0.descriptorID, $0) })
        placed = providerOrder.flatMap { providerID in
            metricOrder(for: providerID).compactMap { byDescriptor[$0] }
        }
        if persistChanges { persist() }
    }

}

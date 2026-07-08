import SwiftUI
import Observation

/// Mutable layout: which widgets are enabled, provider order, and each provider's metric order.
/// `placed` is the enabled set (with stable widget ids); `metricOrderByProvider` is the user's custom order.
@MainActor
@Observable
final class LayoutStore {
    var placed: [PlacedWidget]

    /// In-popover navigation (screen, Customize master/detail, screen-switch slide). Its own store so
    /// screen routing isn't tangled with layout state; the `screen`/`isEditing`/`customizeProviderID`/
    /// `screenSlide*` surface below forwards to it, so existing call sites are unchanged. Private so the
    /// forwarding surface stays the ONLY spelling — two live paths to the same state invites drift.
    private let navigation = PopoverNavigationStore()

    /// Which in-popover screen is showing. Drives the footer buttons, the Esc handler, and the
    /// popover-closed reset alike.
    var screen: PopoverScreen {
        get { navigation.screen }
        set { navigation.screen = newValue }
    }
    /// The screen being left plus a per-switch counter, for DashboardView's horizontal slide.
    var screenSlideFrom: PopoverScreen { navigation.screenSlideFrom }
    var screenSlideID: Int { navigation.screenSlideID }
    /// Whether the Customize screen is showing — a bridge over `screen` for edit-mode call sites.
    var isEditing: Bool {
        get { navigation.isEditing }
        set { navigation.isEditing = newValue }
    }
    /// The provider whose Customize detail (L2) is showing (nil shows the L1 list).
    var customizeProviderID: String? {
        get { navigation.customizeProviderID }
        set { navigation.customizeProviderID = newValue }
    }
    /// Placed widget being drag-reordered (transient). `PlacedWidget.id`, never persisted.
    var draggingID: UUID?
    /// Persisted provider display order (provider IDs). Drives both the dashboard groups and the
    /// Customize sections, so the user can drag whole providers into the order they want.
    var providerOrder: [String]
    /// Persisted metric order within each provider. Toggle switches do not mutate this, so turning a metric on
    /// or off never makes rows jump around in Customize.
    var metricOrderByProvider: [String: [String]]

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
    private let pinNotice = TransientNotice<String?>(clearedValue: nil, timeout: .seconds(3))
    private let shareNotice = TransientNotice<Bool>(clearedValue: false, timeout: .seconds(2.5))
    private let customizeNotice = TransientNotice<CustomizationNoticeContent?>(clearedValue: nil, timeout: .seconds(2.5))

    /// Transient explanation for a denied pin attempt; the popover footer renders it in place of the pin
    /// counter. Set by `notePinDenied`, auto-cleared a few seconds later.
    var pinLimitNotice: String? { pinNotice.value }
    /// Bumped on every denied pin click so the footer notice plays its deny shake each time.
    var pinNoticeShakeTrigger: Int { pinNotice.trigger }

    /// Transient "Copied to clipboard" confirmation for the floating pill above the footer.
    var shareConfirmation: Bool { shareNotice.value }
    /// Bumped on every successful share so the pill replays its pop-in even on a repeat copy.
    var shareConfirmationTrigger: Int { shareNotice.trigger }

    /// Transient in-Customize notice (e.g. "Starred for menu bar", or the orange cap denial).
    var customizationNotice: String? { customizeNotice.value?.message }
    /// The notice's tone: `.positive` (green checkmark) or `.notice` (orange denial). Falls back to
    /// `.positive` once cleared (tone is only read while `customizationNotice` is non-nil, so the
    /// snap-back is unobservable — message and tone now clear atomically, which the old split state
    /// machine couldn't guarantee).
    var customizationNoticeTone: CustomizationNoticeTone { customizeNotice.value?.tone ?? .positive }
    /// Bumped on every present so the pill replays its pop-in even when the same notice repeats.
    var customizationNoticeTrigger: Int { customizeNotice.trigger }

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
        didSet { defaults.set(menuBarStyle.rawValue, forKey: menuBarStyleKey) }
    }

    private let registry: WidgetRegistry
    private let defaults: UserDefaults
    private let storageKey: String
    private let providerOrderKey: String
    private let metricOrderKey: String
    private let seededDefaultsKey: String
    private let pinsKey: String
    private let expandedMetricsKey: String
    private let expandOnEnableKey: String
    private let expandedProvidersKey: String
    private let menuBarStyleKey: String
    private let defaultMetricIDs: [String]
    private let migrationBaselineMetricIDs: [String]
    private let defaultPinnedMetricIDs: [String]
    private let defaultExpandedMetricIDs: [String]
    private var defaultExpandedOnEnableIDs: Set<String>
    private let isProviderEnabled: @MainActor (String) -> Bool

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
        self.defaults = defaults
        self.storageKey = storageKey
        self.providerOrderKey = "\(storageKey).providerOrder"
        self.metricOrderKey = "\(storageKey).metricOrderByProvider"
        self.seededDefaultsKey = "\(storageKey).seededDefaults"
        self.pinsKey = "\(storageKey).menuBarPins"
        self.expandedMetricsKey = "\(storageKey).expandedMetrics"
        self.expandOnEnableKey = "\(storageKey).expandOnEnable"
        self.expandedProvidersKey = "\(storageKey).expandedProviders"
        self.menuBarStyleKey = "\(storageKey).menuBarStyle"
        self.defaultMetricIDs = defaultMetricIDs
        self.migrationBaselineMetricIDs = migrationBaselineMetricIDs
        self.defaultPinnedMetricIDs = defaultPinnedMetricIDs
        self.defaultExpandedMetricIDs = defaultExpandedMetricIDs
        self.isProviderEnabled = isProviderEnabled

        let hasStoredLayout = defaults.data(forKey: storageKey) != nil
        var initialPlaced: [PlacedWidget]
        if let saved = Self.decodeStored([PlacedWidget].self, from: defaults, forKey: storageKey) {
            initialPlaced = saved.filter { registry.descriptor(id: $0.descriptorID) != nil }
        } else {
            initialPlaced = defaultMetricIDs
                .filter { registry.descriptor(id: $0) != nil }
                .map { PlacedWidget(descriptorID: $0) }
        }
        let seededResult = Self.seedNewDefaultMetrics(
            into: initialPlaced,
            defaults: defaults,
            key: seededDefaultsKey,
            hasStoredLayout: hasStoredLayout,
            registry: registry,
            defaultMetricIDs: defaultMetricIDs,
            migrationBaselineMetricIDs: migrationBaselineMetricIDs
        )
        initialPlaced = seededResult.placed
        placed = initialPlaced

        let initialProviderOrder: [String]
        if let saved = Self.decodeStored([String].self, from: defaults, forKey: providerOrderKey) {
            initialProviderOrder = saved
        } else {
            initialProviderOrder = registry.providers.map(\.id)
        }
        providerOrder = initialProviderOrder

        let initialMetricOrder: [String: [String]]
        if let saved = Self.decodeStored([String: [String]].self, from: defaults, forKey: metricOrderKey) {
            initialMetricOrder = Self.normalizedMetricOrder(saved, registry: registry)
        } else {
            initialMetricOrder = Self.defaultMetricOrder(registry: registry)
        }
        metricOrderByProvider = initialMetricOrder

        // Seed default pins on first launch (no saved value) so the menu bar shows real numbers out of
        // the box; a saved value — including an empty one the user produced by unpinning — is respected.
        if let savedPins = defaults.stringArray(forKey: pinsKey) {
            pinnedMetricIDs = Set(savedPins.filter { registry.descriptor(id: $0) != nil })
        } else {
            pinnedMetricIDs = Set(defaultPinnedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        }

        // Seed default expanded membership only on a genuinely fresh launch. An existing layout with no
        // saved value predates this feature, so its metrics stay always-shown — never silently tuck a
        // metric the user already lived with behind a new caret.
        var shouldPersistExpanded = false
        if let savedExpanded = defaults.stringArray(forKey: expandedMetricsKey) {
            expandedMetricIDs = Set(savedExpanded.filter { registry.descriptor(id: $0) != nil })
        } else if hasStoredLayout {
            expandedMetricIDs = []
        } else {
            expandedMetricIDs = Set(defaultExpandedMetricIDs.filter { registry.descriptor(id: $0) != nil })
            shouldPersistExpanded = true
        }
        // Finalized below once `expandedMetricIDs` is settled; seeded here so every stored property is
        // initialized before the reads that compute the real value.
        defaultExpandedOnEnableIDs = []
        menuBarStyle = defaults.enumValue(forKey: menuBarStyleKey, default: .text)

        if let savedExpandedProviders = defaults.stringArray(forKey: expandedProvidersKey) {
            expandedProviderIDs = Set(savedExpandedProviders.filter { registry.provider(id: $0) != nil })
        } else {
            expandedProviderIDs = []
        }
        // A metric added to the defaults since the user's last layout (auto-enabled above by
        // `seedNewDefaultMetrics`) is brand new to them — so when it's a default-expanded metric, tuck it
        // below the caret now instead of surfacing it above the fold. Without this, an existing layout's
        // saved (or empty) expanded set never learns about the new metric and it lands always-shown. Only
        // newly-placed ids qualify, so a metric the user already lived with is never silently hidden.
        let newlyExpanded = Set(seededResult.newlyPlaced)
            .intersection(defaultExpandedMetricIDs)
            .filter { registry.descriptor(id: $0) != nil }
        if !newlyExpanded.isSubset(of: expandedMetricIDs) {
            expandedMetricIDs.formUnion(newlyExpanded)
            shouldPersistExpanded = true
        }

        // A default-expanded metric that is neither already an expanded member nor placed enters below
        // the caret the first time the user enables it. This queue is *persisted*, not recomputed each
        // launch: a saved set is loaded as-is (only re-filtered for metrics that have since been placed
        // or expanded), so a metric the user explicitly moved above the fold while disabled — which
        // consumes its queue entry — stays above the fold after a relaunch instead of being resurrected.
        // It's seeded once (no saved value yet) from the default-expanded metrics not already shown, which
        // is what carries a legacy layout's optional metrics (e.g. `cursor.requests`) below the caret.
        let placedIDs = Set(placed.map(\.descriptorID))
        let expandedNow = expandedMetricIDs
        let isExpandOnEnableCandidate: (String) -> Bool = { [registry] id in
            registry.descriptor(id: id) != nil && !expandedNow.contains(id) && !placedIDs.contains(id)
        }
        if let savedOnEnable = defaults.stringArray(forKey: expandOnEnableKey) {
            defaultExpandedOnEnableIDs = Set(savedOnEnable.filter(isExpandOnEnableCandidate))
        } else {
            defaultExpandedOnEnableIDs = Set(defaultExpandedMetricIDs.filter(isExpandOnEnableCandidate))
            persistExpandOnEnable()
        }

        if shouldPersistExpanded { persistExpanded() }

        if seededResult.shouldPersistSeededDefaults {
            persistSeededDefaults(seededResult.seededDefaults)
        }
        syncPlacedOrder(persistChanges: seededResult.shouldPersistPlaced)
    }

    func provider(id: String) -> Provider? { registry.provider(id: id) }

    func descriptor(for widget: PlacedWidget) -> WidgetDescriptor? {
        registry.descriptor(id: widget.descriptorID)
    }

    private func providerID(of widget: PlacedWidget) -> String? {
        registry.descriptor(id: widget.descriptorID)?.providerID
    }

    var visiblePlaced: [PlacedWidget] {
        placed.filter { widget in
            guard let providerID = providerID(of: widget) else { return true }
            return isProviderEnabled(providerID)
        }
    }

    var availableToAdd: [WidgetDescriptor] {
        let placedIDs = Set(placed.map(\.descriptorID))
        return registry.descriptors.filter { !placedIDs.contains($0.id) && isProviderEnabled($0.providerID) }
    }

    func isMetricEnabled(_ descriptorID: String) -> Bool {
        placed.contains { $0.descriptorID == descriptorID }
    }

    /// Whether any enabled provider ships the local spend tiles — the capability gate for the
    /// Total Spend card. Keyed off the registry's descriptors, not off refreshed data, so the card
    /// can show its "No spend data" state on a fresh morning instead of vanishing.
    var hasSpendCapableProvider: Bool {
        !spendCapableProviders.isEmpty
    }

    /// Enabled providers that ship the local spend tiles (`WidgetDescriptor.spendTiles`), in the
    /// user's provider order — the exact set the Total Spend card aggregates. Deliberately *not*
    /// `displayGroups`: a provider whose every metric is hidden in Customize still spends money and
    /// must still count, and look-alike dollar rows from other providers (OpenRouter's API-spend
    /// "Today") must not.
    var spendCapableProviders: [Provider] {
        let capableIDs = Set(registry.descriptors.filter(\.isSpendTile).map(\.providerID))
        return orderedProviders().filter { capableIDs.contains($0.id) && isProviderEnabled($0.id) }
    }

    // MARK: - Provider grouping

    /// Known providers in the user's saved order, with any not-yet-seen provider appended in registry order
    /// so a newly added provider still shows up.
    private func orderedProviderIDs() -> [String] {
        let known = registry.providers.map(\.id)
        let ordered = providerOrder.filter { known.contains($0) }
        let missing = known.filter { !ordered.contains($0) }
        return ordered + missing
    }

    private func orderedProviders() -> [Provider] {
        orderedProviderIDs().compactMap { registry.provider(id: $0) }
    }

    /// Enabled (and provider-enabled) widgets grouped by provider, in the user's provider order, each
    /// provider's metrics kept in the provider's custom metric order. Drives the grouped dashboard list; providers with
    /// no visible metric are dropped so the dashboard only shows groups that have something to show.
    var displayGroups: [ProviderGroup] {
        orderedProviders().compactMap { provider in
            let widgetsByDescriptor = Dictionary(
                visiblePlaced
                    .filter { providerID(of: $0) == provider.id }
                    .map { ($0.descriptorID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let widgets = metricOrder(for: provider.id).compactMap { widgetsByDescriptor[$0] }
            guard !widgets.isEmpty else { return nil }
            let alwaysShown = widgets.filter { !expandedMetricIDs.contains($0.descriptorID) }
            let expanded = widgets.filter { expandedMetricIDs.contains($0.descriptorID) }
            // A provider whose only enabled metrics are all marked expanded would otherwise render an
            // empty card with a caret — promote them to always-shown so the card always has rows.
            if alwaysShown.isEmpty {
                return ProviderGroup(provider: provider, alwaysShownWidgets: expanded, expandedWidgets: [])
            }
            return ProviderGroup(provider: provider, alwaysShownWidgets: alwaysShown, expandedWidgets: expanded)
        }
    }

    /// Every enabled provider with *all* the metrics it supports, in its saved metric order. Enabled and
    /// disabled rows stay in-place; the switch only controls visibility.
    var customizeGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            guard isProviderEnabled(provider.id) else { return nil }
            let metrics = orderedSupportedMetrics(for: provider.id)
            guard !metrics.isEmpty else { return nil }
            return ProviderMetrics(
                provider: provider,
                alwaysShownMetrics: metrics.filter { !expandedMetricIDs.contains($0.id) },
                expandedMetrics: metrics.filter { expandedMetricIDs.contains($0.id) }
            )
        }
    }

    /// The L1 Customize list: every known provider in the user's saved order, regardless of enablement.
    /// Disabled providers appear here (greyed in the UI) so the user can re-enable them or open their
    /// detail — unlike `customizeGroups`, which filters them out for the dashboard and the old flat
    /// Customize. Each row carries the enablement flag, the total metric count (the badge number), and
    /// the pinned count.
    var customizeProviderRows: [ProviderRow] {
        orderedProviders().map { provider in
            ProviderRow(
                provider: provider,
                isEnabled: isProviderEnabled(provider.id),
                metricCount: metricCount(for: provider.id),
                pinnedCount: pinnedCount(forProvider: provider.id)
            )
        }
    }

    /// Total metrics a provider supports — the L1 row's badge number. Registry descriptor count,
    /// independent of how many the user has enabled.
    func metricCount(for providerID: String) -> Int {
        registry.descriptors(for: providerID).count
    }

    /// The L2 Customize detail for one provider: every metric it supports, split across the
    /// "Always Visible" / "On Demand" divider, in its saved metric order. Available even when the
    /// provider is disabled so L2 can render dimmed-but-editable. nil for an unknown provider or one
    /// with no metrics — the per-provider slice of `customizeGroups` without the enablement guard.
    func customizeDetail(for providerID: String) -> ProviderMetrics? {
        guard let provider = registry.provider(id: providerID) else { return nil }
        let metrics = orderedSupportedMetrics(for: providerID)
        guard !metrics.isEmpty else { return nil }
        return ProviderMetrics(
            provider: provider,
            alwaysShownMetrics: metrics.filter { !expandedMetricIDs.contains($0.id) },
            expandedMetrics: metrics.filter { expandedMetricIDs.contains($0.id) }
        )
    }

    /// A provider's supported metrics in custom order, independent of whether each metric is enabled.
    func orderedSupportedMetrics(for providerID: String) -> [WidgetDescriptor] {
        metricOrder(for: providerID).compactMap { registry.descriptor(id: $0) }
    }

    func metricOrderWithDivider(for providerID: String, dividerID: String) -> [String] {
        let ordered = orderedSupportedMetrics(for: providerID).map(\.id)
        return ordered.filter { !expandedMetricIDs.contains($0) }
            + [dividerID]
            + ordered.filter { expandedMetricIDs.contains($0) }
    }

    func isProviderExpanded(_ providerID: String) -> Bool {
        expandedProviderIDs.contains(providerID)
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
            let rest = orderedProviderIDs().filter { !next.contains($0) }
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

    /// Move a metric across the "Shown on expand" divider without a drag. Moving into the expanded
    /// section parks it as the first expanded metric; moving back parks it as the last always-shown
    /// metric, so the stored order stays grouped the way it renders. Returns whether anything changed.
    /// (Customize now moves metrics via `applyMetricDividerOrder`/`reorderMetric`; this direct toggle is
    /// retained as the concise expand-state mutator the tests drive and for a future per-row control.)
    @discardableResult
    func setMetricExpanded(_ descriptorID: String, _ expanded: Bool) -> Bool {
        recordingUndoStep { setMetricExpandedImpl(descriptorID, expanded) }
    }

    private func setMetricExpandedImpl(_ descriptorID: String, _ expanded: Bool) -> Bool {
        guard let providerID = registry.descriptor(id: descriptorID)?.providerID else { return false }
        guard expandedMetricIDs.contains(descriptorID) != expanded else { return false }
        if defaultExpandedOnEnableIDs.remove(descriptorID) != nil { persistExpandOnEnable() }

        let ordered = metricOrder(for: providerID)
        guard ordered.contains(descriptorID) else { return false }

        if expanded {
            expandedMetricIDs.insert(descriptorID)
        } else {
            expandedMetricIDs.remove(descriptorID)
        }
        // Reinsert the moved metric right at the divider — last always-shown going up, first expanded
        // going down — which is the same position in the combined sequence either way.
        let alwaysShown = ordered.filter { $0 != descriptorID && !expandedMetricIDs.contains($0) }
        let expandedIDs = ordered.filter { $0 != descriptorID && expandedMetricIDs.contains($0) }
        metricOrderByProvider[providerID] = alwaysShown + [descriptorID] + expandedIDs
        persistMetricOrder()
        persistExpanded()
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

    private static func mergingMissingMetrics(into ordered: [String], previous: [String]) -> [String] {
        let orderedSet = Set(ordered)
        var result: [String] = []
        var emitted = Set<String>()
        var orderedIndex = ordered.startIndex

        func emitDesiredRows(through id: String) {
            while orderedIndex < ordered.endIndex {
                let next = ordered[orderedIndex]
                orderedIndex = ordered.index(after: orderedIndex)
                if emitted.insert(next).inserted {
                    result.append(next)
                }
                if next == id { break }
            }
        }

        for id in previous {
            if orderedSet.contains(id) {
                emitDesiredRows(through: id)
            } else if emitted.insert(id).inserted {
                result.append(id)
            }
        }

        while orderedIndex < ordered.endIndex {
            let next = ordered[orderedIndex]
            orderedIndex = ordered.index(after: orderedIndex)
            if emitted.insert(next).inserted {
                result.append(next)
            }
        }

        return result
    }

    /// Pure reorder: remove `dragged`, reinsert it adjacent to `target` (after it when moving down, before
    /// it when moving up). Returns nil when either id is missing or they're identical. Mirrors the proven
    /// macOS drag-reorder math from crafcat7/Peakmon (Apache-2.0).
    static func reordered(_ ids: [String], dragged: String, target: String) -> [String]? {
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target) else { return nil }
        var next = ids
        next.remove(at: from)
        guard let adjusted = next.firstIndex(of: target) else { return nil }
        let insert = from < to ? adjusted + 1 : adjusted
        next.insert(dragged, at: min(insert, next.count))
        return next
    }

    // MARK: - Menu bar pins

    /// Per-provider cap is a rendering constraint — the Text strip stacks a provider's values two to a
    /// column, so a third would not fit the menu bar height.
    static let maxPinsPerProvider = 2

    func isPinned(_ descriptorID: String) -> Bool { pinnedMetricIDs.contains(descriptorID) }

    var pinnedCount: Int { pinnedMetricIDs.count }

    func pinnedCount(forProvider providerID: String) -> Int {
        pinnedMetricIDs.count { registry.descriptor(id: $0)?.providerID == providerID }
    }

    /// Whether `descriptorID` can be newly pinned without breaking a cap. Already-pinned ids return
    /// `true`, so the toggle stays active for unpinning.
    func canPin(_ descriptorID: String) -> Bool {
        if pinnedMetricIDs.contains(descriptorID) { return true }
        guard let descriptor = registry.descriptor(id: descriptorID), descriptor.pinnable else { return false }
        if pinnedCount(forProvider: descriptor.providerID) >= Self.maxPinsPerProvider { return false }
        return true
    }

    /// Why `descriptorID` can't be pinned right now, or `nil` when it can. The single source for the
    /// pin button's tooltip and the denied-click feedback, so both always state the same rule.
    func pinDenialReason(_ descriptorID: String) -> String? {
        guard !canPin(descriptorID) else { return nil }
        if let providerID = registry.descriptor(id: descriptorID)?.providerID,
           pinnedCount(forProvider: providerID) >= Self.maxPinsPerProvider {
            return "Up to \(Self.maxPinsPerProvider) stars per provider"
        }
        return nil
    }

    /// Record a denied pin attempt so the footer can explain the cap (shown for a few seconds,
    /// with a deny shake on every attempt).
    func notePinDenied(_ descriptorID: String) {
        guard let reason = pinDenialReason(descriptorID) else { return }
        pinNotice.present(reason)
    }

    /// Record a successful "Share Screenshot" copy so the floating "Copied to clipboard" pill can
    /// confirm it. Shown for a couple of seconds then cleared — the success-side counterpart to
    /// `notePinDenied`'s transient denial notice, with the same lifecycle.
    func presentShareConfirmation() {
        shareNotice.present(true)
    }

    /// Clear any showing "Copied to clipboard" confirmation and cancel its auto-clear task. Called when
    /// the popover closes so a pill mid-countdown can't reappear stale on the next open — the timer is
    /// otherwise the only clearer, and the layout store outlives the popover.
    func clearShareConfirmation() {
        shareNotice.clear()
    }

    /// Show a transient in-Customize pill (the floating confirmation above the Customize content).
    /// `tone` picks the green success style or the orange denial style. Auto-clears after a couple of
    /// seconds; also cleared on popover close via `clearCustomizationNotice`.
    func presentCustomizationNotice(_ message: String, tone: CustomizationNoticeTone = .positive) {
        customizeNotice.present(CustomizationNoticeContent(message: message, tone: tone))
    }

    /// Clear any showing Customize pill and cancel its auto-clear task. Called when the popover closes
    /// so a pill mid-countdown can't reappear stale on the next open.
    func clearCustomizationNotice() {
        customizeNotice.clear()
    }

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

    func togglePin(_ descriptorID: String) {
        setPinned(!isPinned(descriptorID), for: descriptorID)
    }

    /// Pinned metrics grouped by provider, in the user's Customize order (provider order, then each
    /// provider's metric order). A temporarily disabled provider is excluded from the rendered groups
    /// but keeps its pins. Drives the menu-bar strip.
    var pinnedGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            guard isProviderEnabled(provider.id) else { return nil }
            // Keep the strip order matching Customize: always-shown pins first, then expanded ones.
            let metrics = orderedSupportedMetrics(for: provider.id).filter { pinnedMetricIDs.contains($0.id) }
            return metrics.isEmpty ? nil : ProviderMetrics(
                provider: provider,
                alwaysShownMetrics: metrics.filter { !expandedMetricIDs.contains($0.id) },
                expandedMetrics: metrics.filter { expandedMetricIDs.contains($0.id) }
            )
        }
    }

    private func persistPins() {
        defaults.set(Array(pinnedMetricIDs), forKey: pinsKey)
    }

    private func persistExpanded() {
        defaults.set(Array(expandedMetricIDs), forKey: expandedMetricsKey)
    }

    private func persistExpandOnEnable() {
        defaults.set(Array(defaultExpandedOnEnableIDs), forKey: expandOnEnableKey)
    }

    private func persistExpandedProviders() {
        defaults.set(Array(expandedProviderIDs), forKey: expandedProvidersKey)
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
        metricOrderByProvider = Self.defaultMetricOrder(registry: registry)
        persistMetricOrder()
        pinnedMetricIDs = Set(defaultPinnedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        persistPins()
        expandedMetricIDs = Set(defaultExpandedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        defaultExpandedOnEnableIDs = []
        persistExpanded()
        persistExpandOnEnable()
        expandedProviderIDs = []
        persistExpandedProviders()
        persistSeededDefaults(Set(Self.knownMetricIDs(defaultMetricIDs, registry: registry)))
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

    func cancelDrag() {
        draggingID = nil
    }

    private func persist() {
        persistEncodable(placed, forKey: storageKey)
    }

    private func persistProviderOrder() {
        persistEncodable(providerOrder, forKey: providerOrderKey)
    }

    private func persistMetricOrder() {
        persistEncodable(metricOrderByProvider, forKey: metricOrderKey)
    }

    private func persistSeededDefaults(_ ids: Set<String>) {
        persistEncodable(Array(ids).sorted(), forKey: seededDefaultsKey)
    }

    /// Fail loudly: a swallowed encode would silently fail to persist a layout change with zero signal,
    /// contradicting the project's loud-fail rule (and `ProviderSnapshotCache.save` one store over).
    private func persistEncodable<T: Encodable>(_ value: T, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            AppLog.warn(.config, "failed to persist layout '\(key)': \(error.localizedDescription)")
        }
    }

    /// Decode a persisted value, distinguishing "no data" (first launch — silent nil) from "present but
    /// undecodable" (schema drift / corruption — warn loudly, then nil so init reseeds the default).
    /// A silent reseed of the user's customized layout is exactly the invisible state loss the rule forbids.
    private static func decodeStored<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.warn(.config, "saved layout '\(key)' failed to decode; reseeding default: \(error.localizedDescription)")
            return nil
        }
    }

    private struct SeededDefaultsResult {
        let placed: [PlacedWidget]
        let seededDefaults: Set<String>
        let shouldPersistPlaced: Bool
        let shouldPersistSeededDefaults: Bool
        /// Metric ids newly auto-enabled this launch (a default added since the user's last layout).
        /// Brand-new metrics the user never lived with, so a default-expanded one among them can be
        /// tucked below the caret without the "don't silently hide a metric they already saw" concern.
        let newlyPlaced: [String]
    }

    private static func seedNewDefaultMetrics(
        into placed: [PlacedWidget],
        defaults: UserDefaults,
        key: String,
        hasStoredLayout: Bool,
        registry: WidgetRegistry,
        defaultMetricIDs: [String],
        migrationBaselineMetricIDs: [String]
    ) -> SeededDefaultsResult {
        let knownDefaults = knownMetricIDs(defaultMetricIDs, registry: registry)
        let knownDefaultSet = Set(knownDefaults)
        let hasStoredSeededDefaults = defaults.data(forKey: key) != nil

        let seededDefaults: Set<String>
        var shouldPersistSeededDefaults = false
        if let saved = decodeStored([String].self, from: defaults, forKey: key) {
            seededDefaults = Set(knownMetricIDs(saved, registry: registry))
            shouldPersistSeededDefaults = seededDefaults != Set(saved)
        } else if hasStoredLayout {
            seededDefaults = Set(knownMetricIDs(migrationBaselineMetricIDs, registry: registry))
            shouldPersistSeededDefaults = true
        } else {
            seededDefaults = knownDefaultSet
            shouldPersistSeededDefaults = true
        }

        let placedIDs = Set(placed.map(\.descriptorID))
        let toAdd = knownDefaults.filter { !seededDefaults.contains($0) && !placedIDs.contains($0) }
        let nextPlaced = placed + toAdd.map { PlacedWidget(descriptorID: $0) }
        let nextSeededDefaults = seededDefaults.union(knownDefaultSet)
        shouldPersistSeededDefaults = shouldPersistSeededDefaults
            || !hasStoredSeededDefaults
            || nextSeededDefaults != seededDefaults

        return SeededDefaultsResult(
            placed: nextPlaced,
            seededDefaults: nextSeededDefaults,
            shouldPersistPlaced: !toAdd.isEmpty,
            shouldPersistSeededDefaults: shouldPersistSeededDefaults,
            newlyPlaced: toAdd
        )
    }

    private static func knownMetricIDs(_ ids: [String], registry: WidgetRegistry) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            guard registry.descriptor(id: id) != nil, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    private func metricOrder(for providerID: String) -> [String] {
        let valid = registry.descriptors(for: providerID).map(\.id)
        let saved = metricOrderByProvider[providerID] ?? []
        return Self.normalizedMetricIDs(saved, validIDs: valid)
    }

    private func syncPlacedOrder(persistChanges: Bool = true) {
        let byDescriptor = Dictionary(
            placed.map { ($0.descriptorID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var ordered: [PlacedWidget] = []
        for providerID in orderedProviderIDs() {
            ordered.append(contentsOf: metricOrder(for: providerID).compactMap { byDescriptor[$0] })
        }
        let orderedIDs = Set(ordered.map(\.id))
        ordered.append(contentsOf: placed.filter { !orderedIDs.contains($0.id) })
        placed = ordered
        if persistChanges { persist() }
    }

    private static func defaultMetricOrder(registry: WidgetRegistry) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for provider in registry.providers {
            let valid = registry.descriptors(for: provider.id).map(\.id)
            result[provider.id] = valid
        }
        return result
    }

    private static func normalizedMetricOrder(
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

    private static func normalizedMetricIDs(_ saved: [String], validIDs: [String]) -> [String] {
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

/// A provider and its placed (visible) widgets, split into the always-shown rows and the ones tucked
/// behind the dashboard's "show more" caret. Drives the grouped dashboard list.
struct ProviderGroup: Identifiable {
    let provider: Provider
    let alwaysShownWidgets: [PlacedWidget]
    let expandedWidgets: [PlacedWidget]
    var id: String { provider.id }

    /// Every visible widget in display order (always-shown first, then expanded). Used where the split
    /// doesn't matter — reorder id lists and the lifted drag preview.
    var widgets: [PlacedWidget] { alwaysShownWidgets + expandedWidgets }
    var hasExpandedMetrics: Bool { !expandedWidgets.isEmpty }
}

/// A provider and every metric it supports, in the provider's custom order, split across the "Shown on
/// expand" divider. Drives the Customize screen and the menu-bar pin grouping.
struct ProviderMetrics: Identifiable {
    let provider: Provider
    let alwaysShownMetrics: [WidgetDescriptor]
    let expandedMetrics: [WidgetDescriptor]
    var id: String { provider.id }

    init(provider: Provider, alwaysShownMetrics: [WidgetDescriptor], expandedMetrics: [WidgetDescriptor]) {
        self.provider = provider
        self.alwaysShownMetrics = alwaysShownMetrics
        self.expandedMetrics = expandedMetrics
    }

    /// Convenience for callers that don't partition (e.g. tests): everything is always-shown.
    init(provider: Provider, metrics: [WidgetDescriptor]) {
        self.init(provider: provider, alwaysShownMetrics: metrics, expandedMetrics: [])
    }

    /// Every supported metric in custom order (always-shown first, then expanded).
    var metrics: [WidgetDescriptor] { alwaysShownMetrics + expandedMetrics }
    var hasExpandedMetrics: Bool { !expandedMetrics.isEmpty }
}

/// One row in the Customize provider list (L1): the provider plus the derived bits the row renders —
/// whether it's enabled (the master toggle + Active/Inactive label), how many metrics it supports
/// (the badge), and how many are pinned. Drives `CustomizeProviderListView`. Unlike `ProviderMetrics`,
/// this includes disabled providers so they stay visible in the list.
struct ProviderRow: Identifiable {
    let provider: Provider
    let isEnabled: Bool
    let metricCount: Int
    let pinnedCount: Int
    var id: String { provider.id }
}

/// Tone for the transient in-Customize pill (`LayoutStore.customizationNotice`): green success or
/// orange denial.
enum CustomizationNoticeTone {
    case positive
    case notice
}

/// The message + tone carried by the Customize pill's `TransientNotice`, so its two fields clear together.
struct CustomizationNoticeContent {
    var message: String
    var tone: CustomizationNoticeTone
}

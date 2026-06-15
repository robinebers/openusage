import SwiftUI
import Observation

/// The screen showing inside the menu-bar popover. Customize and Settings replace the dashboard
/// in place (the popover has no window stack); Esc backs out to the dashboard first.
enum PopoverScreen: Hashable, Sendable {
    case dashboard
    case customize
    case settings

    /// Left-to-right order for the popover's horizontal screen-switch slide: the dashboard is home on
    /// the left, with Customize and Settings to its right. The slide reads its direction from these
    /// ranks — a higher-ranked target enters from the trailing edge, a lower one from the leading edge.
    var slideRank: Int {
        switch self {
        case .dashboard: 0
        case .customize: 1
        case .settings: 2
        }
    }
}

/// Mutable layout: which widgets are enabled, provider order, and each provider's metric order.
/// `placed` is the enabled set (with stable widget ids); `metricOrderByProvider` is the user's custom order.
@MainActor
@Observable
final class LayoutStore {
    var placed: [PlacedWidget]
    /// Which in-popover screen is showing. Lives here (not per-view state) so the footer buttons,
    /// the Esc handler, and the popover-closed reset all drive the same mode.
    var screen = PopoverScreen.dashboard {
        didSet {
            guard screen != oldValue else { return }
            // Recorded synchronously with the change — not via SwiftUI's `onChange`, which fires a
            // frame later and would let the popover paint the destination before the slide begins.
            // DashboardView reads these on its very next render to slide in from the screen being left.
            screenSlideFrom = oldValue
            screenSlideID &+= 1
        }
    }
    /// Supports DashboardView's horizontal screen-switch slide: the screen being left, plus a counter
    /// that ticks on every switch so the view can detect and animate each transition. UI-only; not persisted.
    private(set) var screenSlideFrom = PopoverScreen.dashboard
    private(set) var screenSlideID = 0
    /// Whether the Customize screen (per-provider metric toggles + reorder) is showing — a bridge
    /// over `screen` for the many call sites that think in terms of edit mode.
    var isEditing: Bool {
        get { screen == .customize }
        set { screen = newValue ? .customize : .dashboard }
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
    /// `canPin` to one global budget of `maxTotalPins`, with at most `maxPinsPerProvider` per provider
    /// (the strip stacks a provider's values in pairs).
    private(set) var pinnedMetricIDs: Set<String>

    /// Transient explanation for a denied pin attempt (the WhatsApp-style "you can only pin N chats"
    /// feedback). Set by `notePinDenied`, cleared automatically a few seconds later; the popover footer
    /// renders it in place of the pin counter. Never persisted.
    private(set) var pinLimitNotice: String?
    /// Bumped on every denied pin click so the footer notice plays its deny shake each time — including
    /// repeated clicks while the notice is already showing (where the text itself doesn't change).
    private(set) var pinNoticeShakeTrigger = 0
    private var pinNoticeClearTask: Task<Void, Never>?

    /// Menu-bar display style (Text strip vs. compact Bars). Persisted; defaults to `.text`.
    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: menuBarStyleKey) }
    }

    private let registry: WidgetRegistry
    private let defaults: UserDefaults
    private let storageKey: String
    private let providerOrderKey: String
    private let metricOrderKey: String
    private let pinsKey: String
    private let menuBarStyleKey: String
    private let isProviderEnabled: @MainActor (String) -> Bool

    init(
        registry: WidgetRegistry,
        defaults: UserDefaults = .standard,
        storageKey: String = "openusage.layout.v1",
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true }
    ) {
        self.registry = registry
        self.defaults = defaults
        self.storageKey = storageKey
        self.providerOrderKey = "\(storageKey).providerOrder"
        self.metricOrderKey = "\(storageKey).metricOrderByProvider"
        self.pinsKey = "\(storageKey).menuBarPins"
        self.menuBarStyleKey = "\(storageKey).menuBarStyle"
        self.isProviderEnabled = isProviderEnabled

        let initialPlaced: [PlacedWidget]
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([PlacedWidget].self, from: data) {
            initialPlaced = saved.filter { registry.descriptor(id: $0.descriptorID) != nil }
        } else {
            initialPlaced = DefaultLayout.metricIDs
                .filter { registry.descriptor(id: $0) != nil }
                .map { PlacedWidget(descriptorID: $0) }
        }
        placed = initialPlaced

        let initialProviderOrder: [String]
        if let data = defaults.data(forKey: providerOrderKey),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            initialProviderOrder = saved
        } else {
            initialProviderOrder = registry.providers.map(\.id)
        }
        providerOrder = initialProviderOrder

        let initialMetricOrder: [String: [String]]
        if let data = defaults.data(forKey: metricOrderKey),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            initialMetricOrder = Self.normalizedMetricOrder(saved, registry: registry, placed: initialPlaced)
        } else {
            initialMetricOrder = Self.defaultMetricOrder(registry: registry, placed: initialPlaced)
        }
        metricOrderByProvider = initialMetricOrder

        // Seed default pins on first launch (no saved value) so the menu bar shows real numbers out of
        // the box; a saved value — including an empty one the user produced by unpinning — is respected.
        if let savedPins = defaults.stringArray(forKey: pinsKey) {
            pinnedMetricIDs = Set(savedPins.filter { registry.descriptor(id: $0) != nil })
        } else {
            pinnedMetricIDs = Set(DefaultLayout.pinnedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        }
        menuBarStyle = defaults.enumValue(forKey: menuBarStyleKey, default: .text)

        syncPlacedOrder(persistChanges: false)
    }

    var providers: [Provider] { registry.providers }
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
            return widgets.isEmpty ? nil : ProviderGroup(provider: provider, widgets: widgets)
        }
    }

    /// Every enabled provider with *all* the metrics it supports, in its saved metric order. Enabled and
    /// disabled rows stay in-place; the switch only controls visibility.
    var customizeGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            guard isProviderEnabled(provider.id) else { return nil }
            let metrics = orderedSupportedMetrics(for: provider.id)
            return metrics.isEmpty ? nil : ProviderMetrics(provider: provider, metrics: metrics)
        }
    }

    /// A provider's supported metrics in custom order, independent of whether each metric is enabled.
    func orderedSupportedMetrics(for providerID: String) -> [WidgetDescriptor] {
        metricOrder(for: providerID).compactMap { registry.descriptor(id: $0) }
    }

    // MARK: - Customize mutations

    /// Toggle a metric on (add to the placed list) or off (remove it). The single seam the Customize
    /// switches drive, so on/off goes through the same add/remove path the rest of the app uses.
    func setMetricEnabled(_ descriptorID: String, _ enabled: Bool) {
        if enabled {
            add(descriptorID)
        } else if let widget = placed.first(where: { $0.descriptorID == descriptorID }) {
            remove(widget.id)
        }
    }

    /// Reorder whole providers when `dragged`'s header is dropped onto `target`'s. Works on the currently
    /// shown (enabled) provider order; disabled providers keep their relative tail position.
    /// Returns whether the order actually changed — the drag gestures key haptics off it.
    @discardableResult
    func reorderProvider(dragged: String, target: String) -> Bool {
        let shown = customizeGroups.map(\.provider.id)
        guard let next = Self.reordered(shown, dragged: dragged, target: target) else { return false }
        let rest = orderedProviderIDs().filter { !next.contains($0) }
        providerOrder = next + rest
        persistProviderOrder()
        syncPlacedOrder()
        return true
    }

    /// Reorder metrics within one provider when `dragged` is dropped onto `target` (both descriptor ids of
    /// that provider). Operates on the provider's full metric order so disabled metrics keep their place too.
    /// Returns whether the order actually changed — the drag gestures key haptics off it.
    @discardableResult
    func reorderMetric(dragged: String, target: String, in providerID: String) -> Bool {
        let ordered = metricOrder(for: providerID)
        guard let next = Self.reordered(ordered, dragged: dragged, target: target) else { return false }
        metricOrderByProvider[providerID] = next
        persistMetricOrder()
        syncPlacedOrder()
        return true
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

    /// One global pin budget: a single number the user can hold in their head ("up to 6 pins"). The
    /// per-provider cap is a rendering constraint — the Text strip stacks a provider's values two to a
    /// column, so a third would not fit the menu bar height.
    static let maxPinsPerProvider = 2
    static let maxTotalPins = 6

    func isPinned(_ descriptorID: String) -> Bool { pinnedMetricIDs.contains(descriptorID) }

    var pinnedCount: Int { pinnedMetricIDs.count }

    func pinnedCount(forProvider providerID: String) -> Int {
        pinnedMetricIDs.reduce(0) { $0 + (registry.descriptor(id: $1)?.providerID == providerID ? 1 : 0) }
    }

    /// Whether `descriptorID` can be newly pinned without breaking a cap. Already-pinned ids return
    /// `true`, so the toggle stays active for unpinning.
    func canPin(_ descriptorID: String) -> Bool {
        if pinnedMetricIDs.contains(descriptorID) { return true }
        guard let providerID = registry.descriptor(id: descriptorID)?.providerID else { return false }
        if pinnedCount(forProvider: providerID) >= Self.maxPinsPerProvider { return false }
        if pinnedCount >= Self.maxTotalPins { return false }
        return true
    }

    /// Why `descriptorID` can't be pinned right now, or `nil` when it can. The single source for the
    /// pin button's tooltip and the denied-click feedback, so both always state the same rule.
    func pinDenialReason(_ descriptorID: String) -> String? {
        guard !canPin(descriptorID) else { return nil }
        if let providerID = registry.descriptor(id: descriptorID)?.providerID,
           pinnedCount(forProvider: providerID) >= Self.maxPinsPerProvider {
            return "Up to \(Self.maxPinsPerProvider) pins per provider"
        }
        return "All \(Self.maxTotalPins) pins already used"
    }

    /// Record a denied pin attempt so the footer can explain the cap (shown for a few seconds,
    /// with a deny shake on every attempt).
    func notePinDenied(_ descriptorID: String) {
        guard let reason = pinDenialReason(descriptorID) else { return }
        pinLimitNotice = reason
        pinNoticeShakeTrigger += 1
        pinNoticeClearTask?.cancel()
        pinNoticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.pinLimitNotice = nil
        }
    }

    /// Pin or unpin a metric for the menu bar. Pinning is a no-op when it would exceed a cap, so callers
    /// can gate the control on `canPin` and trust this never over-pins.
    func setPinned(_ pinned: Bool, for descriptorID: String) {
        if pinned {
            guard canPin(descriptorID), registry.descriptor(id: descriptorID) != nil else { return }
            guard pinnedMetricIDs.insert(descriptorID).inserted else { return }
        } else {
            guard pinnedMetricIDs.remove(descriptorID) != nil else { return }
        }
        persistPins()
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
            let metrics = orderedSupportedMetrics(for: provider.id).filter { pinnedMetricIDs.contains($0.id) }
            return metrics.isEmpty ? nil : ProviderMetrics(provider: provider, metrics: metrics)
        }
    }

    /// Flattened pinned descriptor ids in display order.
    var pinnedDescriptorIDsInOrder: [String] {
        pinnedGroups.flatMap { $0.metrics.map(\.id) }
    }

    private func persistPins() {
        defaults.set(Array(pinnedMetricIDs), forKey: pinsKey)
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
        placed = DefaultLayout.metricIDs
            .filter { registry.descriptor(id: $0) != nil }
            .map { PlacedWidget(descriptorID: $0) }
        metricOrderByProvider = Self.defaultMetricOrder(registry: registry, placed: placed)
        persistMetricOrder()
        pinnedMetricIDs = Set(DefaultLayout.pinnedMetricIDs.filter { registry.descriptor(id: $0) != nil })
        persistPins()
        persist()
    }

    func cancelDrag() {
        draggingID = nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(placed) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func persistProviderOrder() {
        if let data = try? JSONEncoder().encode(providerOrder) {
            defaults.set(data, forKey: providerOrderKey)
        }
    }

    private func persistMetricOrder() {
        if let data = try? JSONEncoder().encode(metricOrderByProvider) {
            defaults.set(data, forKey: metricOrderKey)
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

    private static func defaultMetricOrder(registry: WidgetRegistry, placed: [PlacedWidget]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for provider in registry.providers {
            let valid = registry.descriptors(for: provider.id).map(\.id)
            let placedForProvider = placed.compactMap { widget -> String? in
                guard let descriptor = registry.descriptor(id: widget.descriptorID),
                      descriptor.providerID == provider.id else { return nil }
                return descriptor.id
            }
            result[provider.id] = normalizedMetricIDs(placedForProvider, validIDs: valid)
        }
        return result
    }

    private static func normalizedMetricOrder(
        _ saved: [String: [String]],
        registry: WidgetRegistry,
        placed: [PlacedWidget]
    ) -> [String: [String]] {
        var fallback = defaultMetricOrder(registry: registry, placed: placed)
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

/// A provider and its placed (visible) widgets, in display order. Drives the grouped dashboard list.
struct ProviderGroup: Identifiable {
    let provider: Provider
    let widgets: [PlacedWidget]
    var id: String { provider.id }
}

/// A provider and every metric it supports, in the provider's custom order. Drives the Customize screen.
struct ProviderMetrics: Identifiable {
    let provider: Provider
    let metrics: [WidgetDescriptor]
    var id: String { provider.id }
}

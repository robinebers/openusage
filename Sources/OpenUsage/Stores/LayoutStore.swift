import SwiftUI
import Observation

/// Mutable layout: which metrics are hidden, provider order, and each provider's metric order.
@MainActor
@Observable
final class LayoutStore {
    // Swift's private access is file-scoped. Members shared with `LayoutStore+Customization.swift`
    // stay module-internal below; implementation details used only here remain private.
    /// The metrics the user turned off. Every other metric of every account shows.
    private(set) var hiddenMetricIDs: Set<String> = []

    /// In-popover navigation (screen, Accounts master/detail, screen-switch slide). Its own store so
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
    /// Whether the Accounts screen is showing — a bridge over `screen` for edit-mode call sites.
    var isEditing: Bool {
        get { navigation.isEditing }
        set { navigation.isEditing = newValue }
    }
    /// The account whose Accounts detail (L2) is showing (nil shows the L1 list).
    var customizeProviderID: String? {
        get { navigation.customizeProviderID }
        set { navigation.customizeProviderID = newValue }
    }
    /// Whether the Add Account sheet is showing over the account list.
    var isAddingAccount: Bool {
        get { navigation.isAddingAccount }
        set { navigation.isAddingAccount = newValue }
    }
    /// Whether the popover is on-screen, flipped by `StatusItemController` at its show/hide chokepoints.
    var popoverShown: Bool {
        get { navigation.popoverShown }
        set { navigation.popoverShown = newValue }
    }
    /// Persisted provider display order (provider IDs). Drives both the dashboard groups and the
    /// Accounts list, so the user can drag whole providers into the order they want.
    var providerOrder: [String] = []
    /// Persisted metric order within each provider. Toggle switches do not mutate this, so turning a metric on
    /// or off never makes rows jump around in Accounts.
    var metricOrderByProvider: [String: [String]] = [:]

    /// Descriptor ids pinned to the menu bar. Membership only — display order is derived from the
    /// provider + metric order above, so pins follow the same sequence shown in Accounts. Capped via
    /// `canPin` to at most `maxPinsPerProvider` per provider (the strip stacks a provider's values in pairs).
    private(set) var pinnedMetricIDs: Set<String> = []

    /// The three transient popover pills, each an auto-clearing `TransientNotice`. The public
    /// `pinLimitNotice`/`shareConfirmation`/`customizationNotice` surface below forwards to these.
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

    /// Transient notice on the Accounts screen (e.g. "Starred for menu bar", or the orange cap denial).
    var customizationNotice: String? { customizeNotice.value?.message }
    /// The notice's tone: `.positive` (green checkmark) or `.notice` (orange denial). Falls back to
    /// `.positive` once cleared (tone is only read while `customizationNotice` is non-nil, so the
    /// snap-back is unobservable: message and tone clear atomically).
    var customizationNoticeTone: CustomizationNoticeTone { customizeNotice.value?.tone ?? .positive }
    /// Bumped on every present so the pill replays its pop-in even when the same notice repeats.
    var customizationNoticeTrigger: Int { customizeNotice.trigger }

    /// How many steps ⌘Z can walk back: deep enough for a real editing session without growing unbounded.
    static let maxUndoDepth = 40
    /// Bounded, app-wide undo stack for layout customization (hide/show a metric, reorder metrics or
    /// providers, pin/unpin). UI-only state (not persisted): undo is a
    /// within-session affordance, so a relaunch starts fresh. Each entry is a pre-change `LayoutSnapshot`;
    /// `undo()` pops and restores one.
    private var undoSnapshots: [LayoutSnapshot] = []
    /// True while `undo()` is replaying a snapshot, so the mutations it triggers don't push themselves
    /// back onto the stack (an undo must not be recorded as a new, separately-undoable action).
    private var isApplyingUndo = false

    /// The accounts' providers and metrics. Replaced in place by `apply(registry:)` when accounts change.
    private(set) var registry: WidgetRegistry
    private let persistence: LayoutPersistence
    /// Provider-family default stars ("codex.session"), given to an account the first time it shows up.
    private let defaultPinnedMetricIDs: [String]

    init(
        registry: WidgetRegistry,
        defaults: UserDefaults = .standard,
        storageKey: String = "openusage.layout.v1",
        defaultPinnedMetricIDs: [String] = DefaultLayout.pinnedMetricIDs
    ) {
        self.registry = registry
        self.persistence = LayoutPersistence(defaults: defaults, storageKey: storageKey)
        self.defaultPinnedMetricIDs = defaultPinnedMetricIDs
        loadLayout(newCardIDs: [])
    }

    /// Adopts a new set of accounts without rebuilding anything. Every layout change is persisted as it
    /// happens, so reloading from storage against the new registry keeps the user's arrangement, stars
    /// a new account's defaults, and drops a removed account's hidden metrics, pins, and order.
    func apply(registry: WidgetRegistry) {
        undoSnapshots.removeAll()
        let knownCardIDs = Set(self.registry.providers.map(\.id))
        self.registry = registry
        if let customizeProviderID, registry.provider(id: customizeProviderID) == nil {
            self.customizeProviderID = nil
        }
        loadLayout(newCardIDs: registry.providers.map(\.id).filter { !knownCardIDs.contains($0) })
    }

    /// Reads the saved layout against the current accounts. Saved stars, including none at all, are the
    /// user's choice for the accounts they were made on; an account in `newCardIDs` gets its default stars,
    /// and with no stars saved yet every account has its defaults. Only shown metrics keep a star.
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

    /// `defaultPinnedMetricIDs` on one account: "claude.session" is "claude@1a2b3c4d.session" on
    /// "claude@1a2b3c4d".
    private func defaultPins(forCard cardID: String) -> [String] {
        registry.descriptors(for: cardID).filter { defaultPinnedMetricIDs.contains($0.kindScopedKey) }.map(\.id)
    }

    // MARK: - Layout mutations

    /// Turn a metric on or off: the Accounts screen's switches.
    func setMetricEnabled(_ descriptorID: String, _ enabled: Bool) {
        recordingUndoStep {
            if enabled { show(descriptorID) } else { hide(descriptorID) }
        }
    }

    /// Turn several metrics back on as one undoable step: the dashboard's Show Hidden Metrics.
    func showMetrics(_ descriptorIDs: [String]) {
        recordingUndoStep {
            for id in descriptorIDs { show(id) }
        }
    }

    // MARK: - Undo

    /// Whether there's at least one layout step to walk back: the app-wide ⌘Z handler's no-op guard.
    var canUndo: Bool { !undoSnapshots.isEmpty }

    /// A snapshot of the current undoable layout state.
    private func currentSnapshot() -> LayoutSnapshot {
        LayoutSnapshot(
            hiddenMetricIDs: hiddenMetricIDs,
            providerOrder: providerOrder,
            metricOrderByProvider: metricOrderByProvider,
            pinnedMetricIDs: pinnedMetricIDs
        )
    }

    /// Run a user-facing layout mutation, recording one undo step for it. Snapshots state before the
    /// change and pushes that snapshot only if the change actually altered the layout — so a no-op
    /// action (toggling an already-on metric, dropping a row back where it started) doesn't pollute the
    /// stack with empty steps. Re-entrant calls (a mutation built from smaller ones) and undo replay
    /// itself coalesce into the single outer step via `isApplyingUndo`.
    func recordingUndoStep<T>(_ body: () -> T) -> T {
        // Already inside an undoable scope (or replaying an undo): just run — the outer scope owns the
        // single recorded step, and undo must never record itself.
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

    /// Walk back the most recent layout step, restoring the layout to its state just before that
    /// action. A no-op (returns `false`) when there's nothing to undo. Repeated calls step further back.
    /// Available app-wide (the dashboard's menus and the Accounts screen alike), not just on one screen.
    @discardableResult
    func undo() -> Bool {
        guard let snapshot = undoSnapshots.popLast() else { return false }
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        restore(snapshot)
        return true
    }

    /// Restore every undoable field from a snapshot and persist the result. Called by `undo()`.
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

    // MARK: - Menu bar pins

    /// Per-provider cap is a rendering constraint — the Text strip stacks a provider's values two to a
    /// column, so a third would not fit the menu bar height.
    static let maxPinsPerProvider = 2

    func isPinned(_ descriptorID: String) -> Bool { pinnedMetricIDs.contains(descriptorID) }

    func pinnedCount(forProvider providerID: String) -> Int {
        pinnedMetricIDs.count { registry.descriptor(id: $0)?.providerID == providerID }
    }

    /// Whether `descriptorID` can be newly pinned without breaking a cap. Already-pinned ids return
    /// `true`, so the toggle stays active for unpinning.
    func canPin(_ descriptorID: String) -> Bool {
        if pinnedMetricIDs.contains(descriptorID) { return true }
        guard let descriptor = registry.descriptor(id: descriptorID) else { return false }
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

    /// Show a transient pill on the Accounts screen (the floating confirmation above its content).
    /// `tone` picks the green success style or the orange denial style. Auto-clears after a couple of
    /// seconds; also cleared on popover close via `clearCustomizationNotice`.
    func presentCustomizationNotice(_ message: String, tone: CustomizationNoticeTone = .positive) {
        customizeNotice.present(CustomizationNoticeContent(message: message, tone: tone))
    }

    /// Clear any showing Accounts pill and cancel its auto-clear task. Called when the popover closes
    /// so a pill mid-countdown can't reappear stale on the next open.
    func clearCustomizationNotice() {
        customizeNotice.clear()
    }

    /// Pin or unpin a metric for the menu bar. Pinning is a no-op when it would exceed a cap, so callers
    /// can gate the control on `canPin` and trust this never over-pins. Pinning a hidden metric shows it,
    /// since only shown metrics carry a star. Undoable like the other layout actions — the no-op guards
    /// mean a denied or redundant pin records no step.
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

    // MARK: - Mutations

    func show(_ descriptorID: String) {
        guard hiddenMetricIDs.remove(descriptorID) != nil else { return }
        persistHidden()
    }

    /// Hide a metric. Hiding also takes its star off, so the menu bar drops it too; showing it again
    /// doesn't put the star back.
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

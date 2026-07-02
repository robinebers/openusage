import Foundation
import Observation

/// A compact staleness hint for a provider's on-screen snapshot. `label` is a short, fixed word
/// ("Outdated") that stays narrow next to long plan names like "Super Grok Heavy", while the precise
/// age lives in `tooltip` ("Last updated 3h 12m ago"), revealed on hover.
struct StalenessHint: Equatable {
    let label: String
    let tooltip: String
}

@MainActor
@Observable
final class WidgetDataStore {
    private let registry: WidgetRegistry
    private let providersByID: [String: ProviderRuntime]
    private let cache: ProviderSnapshotCache
    private let defaults: UserDefaults
    /// Whether a provider is currently enabled. Injected so the store consults the single
    /// `ProviderEnablementStore` without owning it; defaults to "all enabled" for tests and previews.
    private let isProviderEnabled: @MainActor (String) -> Bool
    /// The user's widget order (already enablement-filtered) that drives the menu-bar value. Injected
    /// so the store reads `LayoutStore.visiblePlaced` without owning it; defaults to registry order.
    private let orderedDescriptors: @MainActor () -> [WidgetDescriptor]
    /// Clock for the failure-backoff window. Injected so tests can advance time deterministically.
    private let now: () -> Date
    /// Quota-notification preferences (master + per-trigger). Injected; `nil` disables notifications
    /// entirely (tests and previews that don't wire it).
    private let notificationSettings: (@MainActor () -> NotificationSettingsStore)?
    /// Where a fired milestone is delivered: `(idPrefix, title, subtitle, body) -> Bool`. The Bool is
    /// whether it was actually delivered (authorized + scheduled); on false the caller leaves the
    /// milestone un-marked so it retries next pass. Injected so tests can record posts without a live
    /// notification center; defaults to the shared `AppNotifications`.
    private let postNotification: @MainActor (String, String, String, String) async -> Bool

    private static let meterStyleKey = "meterStyle"
    private static let resetDisplayModeKey = "resetDisplayMode"
    private static let alwaysShowPacingKey = "alwaysShowPacing"
    /// How long a provider that just failed is skipped before the loop will probe it again. A failed
    /// refresh isn't cached, so — unlike a success, which the snapshot cache gates for an interval —
    /// nothing else stops the loop from re-probing a broken provider (logged-out Devin/Grok especially)
    /// on every wake, spawning subprocesses and network calls in a tight loop. This negative-cache caps a
    /// failing provider to one probe per window. Shorter than the refresh interval, so the normal
    /// 5-minute heartbeat always retries; it only suppresses the sub-interval re-probes a wake burst
    /// would cause. The manual `force` refresh (⌘R) always bypasses it.
    private static let failureRetryBackoff: TimeInterval = 60

    var snapshots: [String: ProviderSnapshot] = [:]
    var refreshingProviderIDs: Set<String> = []
    /// Wall-clock time the most recent full refresh pass finished. Together with the chosen refresh
    /// cadence it drives the dashboard footer's live "Next update in …" countdown, so the footer reflects
    /// the real schedule instead of a hardcoded value. `nil` until the first pass completes.
    var lastRefreshAt: Date?
    /// Latest refresh error per provider (e.g. "Not logged in. Run `codex` to authenticate."). Set when
    /// a refresh comes back as an error snapshot, cleared on the next successful one. The dashboard
    /// renders it as a warning indicator beside the provider name; the last good snapshot keeps
    /// displaying (stale-while-revalidate) instead of being replaced by dead "No data" rows.
    var providerErrors: [String: String] = [:]

    /// Per-provider earliest next-probe time after a failure (see `failureRetryBackoff`). Not part of
    /// observable UI state, so it's excluded from `@Observable` tracking.
    @ObservationIgnored private var failureRetryAfter: [String: Date] = [:]

    /// Per-metric dedup state for quota notifications, keyed by `providerID + "." + descriptorID`.
    /// Not observable UI state. Dropped for a provider when it's disabled, so re-enabling starts fresh.
    @ObservationIgnored private var notificationState: [String: NotificationState] = [:]

    /// Telemetry hook wired by `AppContainer`. Invoked once per *real* provider fetch — `.refreshed` or
    /// `.failed` only, never the cache-hit/skip/backoff outcomes that the 5-minute timer produces in
    /// bulk — so the recorder can roll daily usage and error counts up into one event per provider per
    /// day. `nil` (and so a no-op) in tests and previews. Not observable UI state.
    @ObservationIgnored var onRefreshOutcome: (@MainActor (String, RefreshOutcome, ErrorCategory?, Bool) -> Void)?

    /// Global meter style: whether every bounded tile (and the menu-bar value) renders as "used" or
    /// "left/remaining". Persisted so the choice survives relaunch; defaults to `.remaining`.
    var meterStyle: WidgetDisplayMode {
        didSet { defaults.set(meterStyle.rawValue, forKey: Self.meterStyleKey) }
    }

    /// Global reset-countdown format: relative ("Resets in 4d 17h") or absolute ("Resets tomorrow at
    /// 9:00 AM"). Persisted across relaunch; defaults to `.relative`. Toggled by clicking a reset label.
    var resetDisplayMode: ResetDisplayMode {
        didSet { defaults.set(resetDisplayMode.rawValue, forKey: Self.resetDisplayModeKey) }
    }

    /// Global "always show pacing" opt-in: when on, on-track rows surface their pace projection (the
    /// blue/healthy row gains its "~N% left at reset" copy + an even-pace tick, the amber tick switches
    /// to the same even-pace line). Persisted across relaunch; defaults to `false` (every row unchanged).
    var alwaysShowPacing: Bool {
        didSet { defaults.set(alwaysShowPacing, forKey: Self.alwaysShowPacingKey) }
    }

    init(
        registry: WidgetRegistry,
        providers: [ProviderRuntime],
        cache: ProviderSnapshotCache = ProviderSnapshotCache(),
        defaults: UserDefaults = .standard,
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true },
        orderedDescriptors: (@MainActor () -> [WidgetDescriptor])? = nil,
        now: @escaping () -> Date = Date.init,
        notificationSettings: (@MainActor () -> NotificationSettingsStore)? = nil,
        postNotification: (@MainActor (String, String, String, String) async -> Bool)? = nil
    ) {
        self.registry = registry
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        self.cache = cache
        self.defaults = defaults
        self.isProviderEnabled = isProviderEnabled
        self.orderedDescriptors = orderedDescriptors ?? { registry.descriptors }
        self.now = now
        self.notificationSettings = notificationSettings
        self.postNotification = postNotification
            ?? { idPrefix, title, subtitle, body in
                await AppNotifications.shared.post(idPrefix: idPrefix, title: title, subtitle: subtitle, body: body)
            }
        self.meterStyle = defaults.enumValue(forKey: Self.meterStyleKey, default: .remaining)
        self.resetDisplayMode = defaults.enumValue(forKey: Self.resetDisplayModeKey, default: .relative)
        self.alwaysShowPacing = defaults.bool(forKey: Self.alwaysShowPacingKey)
        // Stale-while-revalidate: load whatever was cached (expired included) so the menu bar and
        // dashboard show last-known values immediately at launch instead of "—"; the refresh loop
        // replaces them as soon as fresh data lands.
        self.snapshots = cache.loadSnapshots(providerIDs: registry.providers.map(\.id))
    }

    /// Refresh every enabled provider, concurrently — one slow provider never delays the rest.
    /// Everything stays MainActor-isolated; the overlap happens at the network awaits inside each
    /// provider, and the per-provider in-flight guard in `refresh` still prevents duplicate fetches.
    /// `force` bypasses the snapshot cache (the manual "refresh now" path); the periodic loop keeps
    /// honoring it.
    func refreshAll(force: Bool = false) async {
        // `Task {}` from MainActor context inherits the isolation (a task-group child can't capture
        // the non-Sendable store), so: fire one task per provider, then await them all.
        let providerIDs = registry.providers.map(\.id).filter { isProviderEnabled($0) }
        let start = Date()
        AppLog.info(.refresh, "batch start (\(providerIDs.count) providers, force=\(force))")
        let tasks = providerIDs.map { providerID in
            Task { await self.refresh(providerID: providerID, force: force) }
        }
        var outcomes: [RefreshOutcome] = []
        outcomes.reserveCapacity(tasks.count)
        for task in tasks {
            outcomes.append(await task.value)
        }
        // Stamp the end of the pass so the footer countdown targets the next scheduled refresh
        // (this time + one refresh interval), mirroring the periodic loop that sleeps one interval
        // after each pass.
        lastRefreshAt = Date()
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        // Count THIS batch's actual outcomes, not the long-lived `providerErrors` map (which persists
        // across passes, so reading it would miscount cache hits and stale earlier failures).
        let refreshed = outcomes.count { $0 == .refreshed }
        let failed = outcomes.count { $0 == .failed }
        let cached = outcomes.count { $0 == .cacheHit }
        let backedOff = outcomes.count { $0 == .backedOff }
        AppLog.info(.refresh, "batch end (\(durationMs)ms, \(refreshed) ok / \(failed) failed / \(cached) cached / \(backedOff) backed off)")
    }

    /// Evaluate every visible, enabled metric for a quota pace milestone and post a notification for any
    /// that just crossed one. Driven from the periodic loop *after* `refreshAll`, so it catches pace
    /// worsening from time passing (not only from a fresh fetch). Deduped per metric per reset window via
    /// `notificationState`; the no-trustworthy-pace states (no data, fresh session, level bands) never
    /// fire. A no-op when notifications are unconfigured (tests/previews) or all triggers are off.
    ///
    /// State for metrics not visited this pass (e.g. a provider the user just disabled, or a metric
    /// removed from the layout) is pruned, so re-enabling/re-adding starts fresh rather than carrying a
    /// stale "already fired" flag.
    func evaluateNotifications(now: Date = Date()) async {
        guard let settingsProvider = notificationSettings else { return }
        let settings = settingsProvider()
        let toggles = settings.toggles
        var nextState: [String: NotificationState] = [:]
        for descriptor in orderedDescriptors() where isProviderEnabled(descriptor.providerID) {
            let key = "\(descriptor.providerID).\(descriptor.id)"
            let data = data(for: descriptor)
            // Unbounded rows (no limit) and charts have no pace story — skip them outright so they never
            // occupy state. `meterState` returns `.level`/`.noData` for them anyway, which wouldn't fire,
            // but skipping keeps the state map to genuine meters.
            guard data.isBounded else { continue }
            let state = data.meterState(now: now)
            let previous = notificationState[key] ?? NotificationState()
            let currentBucket = PaceNotificationLogic.bucket(for: state)
            let resetDelta = Self.resetDelta(current: data.resetsAt, previous: previous.resetsAt)
            let resetAdvanced = PaceNotificationLogic.resetWindowAdvanced(
                resetsAt: data.resetsAt,
                previousReset: previous.resetsAt
            )
            let result = PaceNotificationLogic.transitions(
                state: state,
                fraction: data.remainingFraction,
                resetsAt: data.resetsAt,
                previous: previous,
                toggles: toggles
            )
            if !result.fire.isEmpty || resetAdvanced || Self.isPositiveResetMovement(resetDelta) {
                AppLog.debug(.notifications, "decision \(key): metric=\(data.title) state=\(Self.notificationStateDescription(state)) bucket=\(Self.bucketDescription(currentBucket)) previousBucket=\(Self.bucketDescription(previous.previousBucket)) remaining=\(Self.percentDescription(data.remainingFraction)) reset=\(Self.dateDescription(data.resetsAt)) previousReset=\(Self.dateDescription(previous.resetsAt)) resetDelta=\(Self.resetDeltaDescription(resetDelta)) resetReason=\(Self.resetReasonDescription(delta: resetDelta, advanced: resetAdvanced)) primed=\(previous.primed) wasUnderTen=\(previous.wasUnderTenPercent) firedBefore=\(Self.milestoneDescription(previous.firedMilestones)) fire=\(Self.milestoneDescription(result.fire)) newBucket=\(Self.bucketDescription(result.newState.previousBucket)) newFired=\(Self.milestoneDescription(result.newState.firedMilestones)) toggles=\(Self.toggleDescription(toggles))")
            }
            // Deliver each fired milestone, then commit dedup state only for the ones that actually
            // delivered. The logic doesn't mark milestones fired — that's done here, after delivery
            // succeeds, so a skipped/failed delivery (not authorized, or `add` errored) leaves the
            // milestone un-marked and the state advance reverted, re-firing on the next pass instead of
            // being lost for the rest of the reset window.
            var next = result.newState
            var paceDelivered = false
            var underDelivered = false
            for milestone in result.fire {
                let delivered = await post(milestone: milestone, data: data, providerID: descriptor.providerID)
                if delivered {
                    if milestone == .underTenPercent { underDelivered = true } else { paceDelivered = true }
                    next.firedMilestones.insert(milestone)
                }
            }
            if result.fire.contains(where: { $0 != .underTenPercent }) && !paceDelivered {
                next.previousBucket = previous.previousBucket
            }
            if result.fire.contains(.underTenPercent) && !underDelivered {
                next.wasUnderTenPercent = previous.wasUnderTenPercent
            }
            if !result.fire.isEmpty {
                AppLog.debug(.notifications, "commit \(key): paceDelivered=\(paceDelivered) underTenDelivered=\(underDelivered) persistedBucket=\(Self.bucketDescription(next.previousBucket)) persistedWasUnderTen=\(next.wasUnderTenPercent) persistedFired=\(Self.milestoneDescription(next.firedMilestones))")
            }
            nextState[key] = next
        }
        notificationState = nextState
    }

    /// Build and post one milestone notification. The title is the trigger name (matches the Settings
    /// row), the subtitle is "Provider Metric" so the user knows which quota worsened, and the body is
    /// the plain-language verdict. Title Case per AGENTS.md. Returns whether delivery succeeded.
    private func post(milestone: PaceMilestone, data: WidgetData, providerID: String) async -> Bool {
        let metricName = data.title
        let providerName = providersByID[providerID]?.provider.displayName ?? providerID
        let subtitle = "\(providerName) \(metricName)"
        return await postNotification(
            "\(providerID).\(milestone.rawValue)",
            milestone.notificationTitle,
            subtitle,
            milestone.body
        )
    }

    // MARK: - Notification decision trace helpers (debug logging only)

    private static func resetDelta(current: Date?, previous: Date?) -> TimeInterval? {
        guard let current, let previous else { return nil }
        return current.timeIntervalSince(previous)
    }

    private static func isPositiveResetMovement(_ delta: TimeInterval?) -> Bool {
        guard let delta else { return false }
        return delta > 0
    }

    private static func resetReasonDescription(delta: TimeInterval?, advanced: Bool) -> String {
        guard let delta else { return "firstOrMissingReset" }
        if advanced { return "advanced" }
        if delta > 0 { return "ignoredJitter" }
        if delta < 0 { return "movedEarlier" }
        return "unchanged"
    }

    private static func resetDeltaDescription(_ delta: TimeInterval?) -> String {
        guard let delta else { return "nil" }
        return String(format: "%.3fs", delta)
    }

    private static func dateDescription(_ date: Date?) -> String {
        date.map { OpenUsageISO8601.string(from: $0) } ?? "nil"
    }

    private static func percentDescription(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func toggleDescription(_ toggles: PaceNotificationToggles) -> String {
        "under10=\(toggles.underTenPercent),close=\(toggles.healthyToClose),runOut=\(toggles.closeToRunningOut)"
    }

    private static func milestoneDescription(_ milestones: Set<PaceMilestone>) -> String {
        milestoneDescription(milestones.sorted { $0.rawValue < $1.rawValue })
    }

    private static func milestoneDescription(_ milestones: [PaceMilestone]) -> String {
        guard !milestones.isEmpty else { return "[]" }
        return "[" + milestones.map(\.rawValue).joined(separator: ",") + "]"
    }

    private static func bucketDescription(_ bucket: PaceBucket) -> String {
        switch bucket {
        case .untracked: return "untracked"
        case .healthy: return "healthy"
        case .close: return "close"
        case .runningOut: return "runningOut"
        }
    }

    private static func notificationStateDescription(_ state: WidgetData.MeterState) -> String {
        switch state {
        case .noData: return "noData"
        case .spent: return "spent"
        case .runningOut: return "runningOut"
        case .closeToLimit: return "closeToLimit"
        case .healthy: return "healthy"
        case .level(let severity):
            switch severity {
            case .normal: return "level.normal"
            case .warning: return "level.warning"
            case .critical: return "level.critical"
            }
        }
    }

    /// What a single provider's refresh actually did this pass, so `refreshAll` can summarize the batch
    /// from real outcomes rather than cumulative error state. `.backedOff` is a probe deliberately skipped
    /// because the provider failed within the last `failureRetryBackoff` — distinct from `.skipped`
    /// (disabled / unknown / already in flight) so a wake-burst's suppression is visible in the logs.
    enum RefreshOutcome: Sendable { case refreshed, failed, cacheHit, skipped, backedOff }

    @discardableResult
    func refresh(providerID: String, force: Bool = false) async -> RefreshOutcome {
        guard isProviderEnabled(providerID) else { return .skipped }
        if !force, let cached = cache.snapshot(providerID: providerID) {
            // Skip the no-op write: `@Observable` doesn't compare values, so unconditionally
            // re-assigning an unchanged snapshot would re-render the menu-bar label every pass.
            AppLog.debug(.refresh, "cache hit \(providerID)")
            if snapshots[providerID] != cached {
                snapshots[providerID] = cached
            }
            return .cacheHit
        }
        if !force { AppLog.debug(.refresh, "cache miss \(providerID)") }

        // A provider that just failed isn't cached, so nothing else stops the loop from re-probing it on
        // every wake. Hold off until its backoff expires; the manual `force` refresh ignores the backoff.
        if !force, let retryAfter = failureRetryAfter[providerID], now() < retryAfter {
            AppLog.debug(.refresh, "backoff skip \(providerID) (failed <\(Int(Self.failureRetryBackoff))s ago)")
            return .backedOff
        }

        guard let provider = providersByID[providerID] else { return .skipped }
        // Skip if an in-flight refresh already owns this provider (e.g. the background timer racing the
        // first popover open), so we never fire duplicate network calls for the same provider.
        guard !refreshingProviderIDs.contains(providerID) else {
            AppLog.debug(.refresh, "cache skip \(providerID) (already in flight)")
            return .skipped
        }
        refreshingProviderIDs.insert(providerID)
        defer { refreshingProviderIDs.remove(providerID) }
        let start = Date()
        let snapshot = await provider.refresh()
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        if let message = Self.errorMessage(in: snapshot) {
            // Failed refresh: surface the error but keep the last good snapshot on screen rather than
            // collapsing every row to "No data". The provider error string is already user-safe.
            providerErrors[providerID] = message
            // Negative-cache the failure so a wake burst can't re-probe this provider in a tight loop.
            failureRetryAfter[providerID] = now().addingTimeInterval(Self.failureRetryBackoff)
            AppLog.warn(.refresh, "\(providerID) failed: \(message)")
            onRefreshOutcome?(providerID, .failed, snapshot.errorCategory, force)
            return .failed
        }
        if providerErrors[providerID] != nil {
            providerErrors[providerID] = nil
        }
        // Recovered: drop any backoff so the provider resumes the normal cadence immediately.
        failureRetryAfter[providerID] = nil
        snapshots[providerID] = snapshot
        cache.store(snapshot)
        AppLog.info(.refresh, "\(providerID) ok (\(durationMs)ms)")
        onRefreshOutcome?(providerID, .refreshed, nil, force)
        return .refreshed
    }

    /// Clears a provider's failure backoff so the next pass probes it immediately. Called when the user
    /// re-enables a provider: the enablement wake exists to fetch promptly, so a stale backoff from a
    /// failure just before it was turned off must not suppress that fetch (the loop wouldn't otherwise
    /// retry until the 5-minute heartbeat). The periodic loop never calls this — only the user action does.
    func clearFailureBackoff(for providerID: String) {
        failureRetryAfter[providerID] = nil
    }

    /// The provider's latest refresh error, or `nil` when its last refresh succeeded.
    func errorMessage(for providerID: String) -> String? {
        providerErrors[providerID]
    }

    /// A soft, non-blocking notice from the provider's latest *successful* snapshot (e.g. Claude's
    /// "Re-login for live usage" when the login lacks the `user:profile` scope). `nil` when there's no
    /// warning. After a *failed* refresh the store keeps the last good snapshot (so this warning can
    /// linger) while setting `providerErrors` — use `headerNotice(for:)` for the rendered triangle so a
    /// current hard error isn't masked by a stale soft warning.
    func warningMessage(for providerID: String) -> String? {
        snapshots[providerID]?.warning
    }

    /// The provider header's amber-triangle notice: a hard refresh error takes precedence over a stale
    /// soft warning from the last successful snapshot. After a failed refresh the store keeps the last
    /// good snapshot (so `warningMessage` still returns its warning) while `errorMessage` holds the
    /// current failure — the error must win, or a stale "Re-login for live usage" warning would hide a
    /// real "Token expired" failure. When there's no error, the soft warning (if any) shows.
    func headerNotice(for providerID: String) -> String? {
        errorMessage(for: providerID) ?? warningMessage(for: providerID)
    }

    /// A snapshot that carries only error lines is a failed refresh; its message comes from the badge.
    private static func errorMessage(in snapshot: ProviderSnapshot) -> String? {
        guard !snapshot.lines.isEmpty, snapshot.lines.allSatisfy(\.isError) else { return nil }
        if case .badge(_, let text, _, _) = snapshot.lines[0] { return text }
        return "Refresh failed"
    }

    func data(for descriptor: WidgetDescriptor) -> WidgetData {
        if PlanWidget.isPlan(descriptor) {
            var result = descriptor.sample
            if let plan = plan(for: descriptor.providerID) {
                result.valueTextOverride = plan
                result.hasData = true
            } else {
                result.hasData = false
            }
            return result
        }

        var result: WidgetData
        if let snapshot = snapshots[descriptor.providerID],
           let line = snapshot.line(label: descriptor.metricLabel),
           let data = resolve(line, descriptor: descriptor) {
            result = data
        } else {
            // No real metric line backs this placed tile, so the sample's numbers are placeholders.
            // Flag it as no-data; the tile renders "No data" instead of inventing usage.
            result = descriptor.sample
            result.hasData = false
        }

        // Single global choke point: tiles, the Add-Widget gallery, and the menu-bar value all funnel
        // through here, so stamping the mode once makes them follow the global setting. Inert for
        // unbounded tiles (limit == nil), whose displayed value ignores displayMode.
        result.displayMode = meterStyle
        result.resetDisplayMode = resetDisplayMode
        result.alwaysShowPacing = alwaysShowPacing
        result.widgetID = descriptor.id
        return result
    }

    /// The plan label for a provider's latest snapshot (also feeds the optional Plan widget). `nil` until a
    /// snapshot exists or when the provider doesn't expose a plan.
    func plan(for providerID: String) -> String? {
        snapshots[providerID]?.plan
    }

    /// How long a displayed snapshot may age before the header calls it out. A healthy provider's
    /// snapshot resets to ~0 on every successful pass and only brushes one interval just before the next
    /// one, so the threshold sits at two intervals: it fires only when a refresh has actually been missed
    /// — a refresh loop that keeps failing, or a long-suspended background timer — never on the normal
    /// per-cycle aging, which would flicker a hint on healthy providers.
    static let stalenessThreshold = RefreshSetting.interval * 2

    /// A compact "Outdated" hint for the provider's on-screen snapshot, surfaced only once that snapshot
    /// has aged past `stalenessThreshold`; `nil` while the data is still current (the common case), so the
    /// header stays clean until staleness is real. The label is short on purpose — a long plan name plus a
    /// full "Updated 3h ago" string would overflow the header — so the precise age rides in the tooltip.
    /// This is the visible counterpart to the silent fossilized-cache problem (#582): a failing-refresh
    /// loop keeps the last good plan/limits on screen, and without this nothing told the user that data was
    /// stale. Reads the store's injected clock, which tests pin to a fixed value.
    func stalenessHint(for providerID: String) -> StalenessHint? {
        guard let refreshedAt = snapshots[providerID]?.refreshedAt else { return nil }
        let age = now().timeIntervalSince(refreshedAt)
        guard age >= Self.stalenessThreshold, let duration = Formatters.compactDuration(age) else {
            return nil
        }
        return StalenessHint(label: "Outdated", tooltip: "Last updated \(duration) ago")
    }

    var menuBarPrimaryText: String {
        // The tray mirrors the user's widget order: the first placed, enabled tile that has real data
        // drives it, skipping any no-data tile so it never shows a missing metric's placeholder. When
        // nothing has real data yet, it shows the no-data marker ("—") beside the tray icon — never a
        // fabricated amount.
        let primary = orderedDescriptors()
            .filter { isProviderEnabled($0.providerID) }
            .lazy
            .map { self.data(for: $0) }
            // A chart tile has data but no scalar value, so it would read "0" here — skip it, the same
            // way the tray bars skip it (it's non-pinnable).
            .first { $0.hasData && !$0.isChart }

        guard let primary else { return WidgetData.noDataHeadline }
        return primary.valueText
    }

    private func resolve(_ line: MetricLine, descriptor: WidgetDescriptor) -> WidgetData? {
        switch line {
        case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _):
            // A percent meter is a bounded 0...100 domain; sanitize an out-of-range sample (a provider
            // reporting a negative or >100 utilization) here, at the single construction choke point
            // every provider funnels through, so no surface — headline, flip tooltip, menu bar — can
            // render "-5%" or "105%". For percent the limit is always 100, so clamping `used` also
            // keeps the meter's spent verdict intact (>=100 still reads "Limit reached"). Non-percent
            // meters keep their raw `used`: a dollar/count overage (used > limit) is real and is
            // conveyed by the meter's spent state rather than hidden.
            let normalizedUsed = format == .percent ? ProviderParse.clampPercent(used) : used
            return WidgetData(
                title: descriptor.sample.title,
                icon: descriptor.sample.icon,
                kind: format.metricKind,
                used: normalizedUsed,
                limit: limit,
                countSuffix: format.countSuffix,
                valuePrefix: descriptor.sample.valuePrefix,
                widgetID: descriptor.id,
                resetsAt: resetsAt,
                periodDurationMs: periodDurationMs,
                limitNoun: descriptor.sample.limitNoun,
                infoNote: descriptor.sample.infoNote
            )
        case .text(_, let value, _, _):
            return resolveText(value, descriptor: descriptor)
        case .values(_, let values, _, let expiriesAt, let unknownModels):
            // The number is carried raw — no regex re-parse. Presentation (title, icon, selection,
            // trailing word) comes from the descriptor's sample; the live numbers come from the line.
            var data = descriptor.sample
            data.values = values
            // A `.values` line is unbounded by definition (see `MetricLine`), so it never renders as a
            // meter even when the descriptor's gallery sample carries a placeholder limit — e.g. Claude's
            // `claude.extra` is `boundedDollars` for its capped `.progress` case but feeds an uncapped
            // `.values` row when there's no monthly cap.
            data.limit = nil
            // Optional expiry instants (Codex rate-limit-reset credits): surfaced in the row's hover
            // tooltip (see `expiryTooltip`), with the row re-rendering on the clock tick so they stay live.
            data.expiriesAt = expiriesAt
            // Unknown-model names (Cursor spend tiles): drive the label warning triangle whose hover lists
            // the models this period used that the pricing manifest can't price, so the cost is incomplete.
            data.unknownModels = unknownModels
            // A tile whose selection finds no value (e.g. a cost-only tile on a day ccusage couldn't
            // price) has nothing real to show — render "No data" rather than a misleading $0.00 / 0.
            data.hasData = !data.selectedValues.isEmpty
            // The ⓘ is data-driven: it shows when a *shown* value is locally estimated (a spend row's
            // dollars) and stays off for a measured one (its tokens), so the tokens-only tile reads clean.
            data.infoNote = data.selectedValues.contains(where: \.estimated)
                ? WidgetData.ccusageEstimateNote
                : descriptor.sample.infoNote
            return data
        case .badge(_, let text, _, let subtitle):
            var data = descriptor.sample
            data.valueTextOverride = text
            data.subtitleOverride = subtitle
            return data
        case .chart(_, let points, let note):
            // Presentation (title, icon) from the sample; the live per-day points from the line. No
            // points means the source was read but had no usable day — render "No data", not an empty
            // axis (and so the sample's gallery bars never leak onto the dashboard).
            var data = descriptor.sample
            data.isChart = true
            data.chartPoints = points
            data.chartNote = note
            data.hasData = !points.isEmpty
            return data
        }
    }

    private func resolveText(_ value: String, descriptor: WidgetDescriptor) -> WidgetData? {
        let sample = descriptor.sample
        switch sample.kind {
        case .dollars:
            guard let amount = Self.firstCurrencyAmount(in: value) else { return sample }
            // A raw-text descriptor shows the provider's line verbatim (the parsed amount above still
            // feeds the menu bar's compact value); otherwise the value is reformatted from `used`.
            return textData(sample, kind: .dollars, used: amount, limit: sample.limit,
                            valueTextOverride: sample.preservesRawText ? value : nil,
                            unboundedValueWord: sample.unboundedValueWord)
        case .count:
            guard let count = Self.firstNumber(in: value) else { return sample }
            // A raw-text descriptor shows the provider's line verbatim (the parsed count above still
            // feeds the menu bar's compact value); otherwise the value is reformatted from `used`.
            return textData(sample, kind: .count, used: count, limit: sample.limit,
                            valueTextOverride: sample.preservesRawText ? value : nil,
                            unboundedValueWord: sample.unboundedValueWord)
        case .percent:
            guard let percent = Self.firstNumber(in: value) else { return sample }
            // Percent rows are always 0–100, so a missing sample limit defaults to a full 100 scale,
            // and they carry no `unboundedValueWord` (they're never an unbounded balance). `firstNumber`
            // accepts a leading sign, so clamp the parsed value to the same 0...100 domain the
            // `.progress` percent path guarantees, keeping a stray "-5%" out of every surface.
            return textData(sample, kind: .percent, used: ProviderParse.clampPercent(percent), limit: sample.limit ?? 100)
        }
    }

    /// Builds the resolved `WidgetData` for a `.text` line: the metric identity and presentation come
    /// from the descriptor's `sample`, while the parsed `used` (and the per-kind `limit`,
    /// `valueTextOverride`, `unboundedValueWord`) come from the live value. Fields the sample uses for
    /// real metrics but a fresh text row must not inherit (display/reset mode, reset timing, period,
    /// limit noun, raw-text flag, no-data flag) deliberately reset to their `WidgetData` defaults.
    private func textData(
        _ sample: WidgetData,
        kind: MetricKind,
        used: Double,
        limit: Double?,
        valueTextOverride: String? = nil,
        unboundedValueWord: String? = nil
    ) -> WidgetData {
        WidgetData(
            title: sample.title,
            icon: sample.icon,
            kind: kind,
            used: used,
            limit: limit,
            countSuffix: sample.countSuffix,
            valuePrefix: sample.valuePrefix,
            valueTextOverride: valueTextOverride,
            subtitleOverride: sample.subtitleOverride,
            unboundedValueWord: unboundedValueWord,
            infoNote: sample.infoNote
        )
    }

    static func firstCurrencyAmount(in value: String) -> Double? {
        let pattern = #"[-+]?\$([0-9][0-9,]*(?:\.[0-9]+)?)"#
        guard let match = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let matched = value[match].replacingOccurrences(of: "$", with: "")
        return Double(matched.replacingOccurrences(of: ",", with: ""))
    }

    static func firstNumber(in value: String) -> Double? {
        let pattern = #"[-+]?[0-9][0-9,]*(?:\.[0-9]+)?"#
        guard let match = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return Double(value[match].replacingOccurrences(of: ",", with: ""))
    }
}


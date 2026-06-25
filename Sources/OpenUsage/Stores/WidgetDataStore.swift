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

    private static let meterStyleKey = "meterStyle"
    private static let resetDisplayModeKey = "resetDisplayMode"
    private static let alwaysShowPacingKey = "alwaysShowPacing"
    /// Providers are considered stale only after a couple of effective refresh windows, so a provider
    /// that is intentionally backed off after failures does not look stale merely because the app is
    /// respecting that backoff.
    private static let stalenessCycleCount: TimeInterval = 2

    var snapshots: [String: ProviderSnapshot] = [:]
    var refreshingProviderIDs: Set<String> = []
    /// Wall-clock time the most recent refresh batch finished. Kept for logs/tests and older callers; the
    /// visible countdown now reads `nextScheduledRefreshDate()` because providers can have different
    /// cadences and failure backoffs.
    var lastRefreshAt: Date?
    /// Latest refresh error per provider (e.g. "Not logged in. Run `codex` to authenticate."). Set when
    /// a refresh comes back as an error snapshot, cleared on the next successful one. The dashboard
    /// renders it as a warning indicator beside the provider name; the last good snapshot keeps
    /// displaying (stale-while-revalidate) instead of being replaced by dead "No data" rows.
    var providerErrors: [String: String] = [:]

    /// Earliest next live probe per provider. A missing value means "due now", which gives launch and
    /// re-enable paths their immediate first fetch.
    var nextProbeAtByProvider: [String: Date] = [:]

    /// Consecutive failed/rate-limited live probes per provider. A success clears the count.
    @ObservationIgnored private var consecutiveFailures: [String: Int] = [:]

    /// The latest effective scheduling interval per provider: base cadence on success, current backoff
    /// after failures. Staleness uses this so intentional backoff does not create a misleading hint.
    @ObservationIgnored private var effectiveRefreshIntervals: [String: TimeInterval] = [:]

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
        now: @escaping () -> Date = Date.init
    ) {
        self.registry = registry
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        self.cache = cache
        self.defaults = defaults
        self.isProviderEnabled = isProviderEnabled
        self.orderedDescriptors = orderedDescriptors ?? { registry.descriptors }
        self.now = now
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
    /// `force` bypasses the snapshot cache and backoff (the manual "refresh now" path).
    func refreshAll(force: Bool = false) async {
        await refreshBatch(
            providerIDs: registry.providers.map(\.id).filter { isProviderEnabled($0) },
            force: force
        )
    }

    /// Refresh only providers whose scheduled live probe is due. The background loop uses this so Codex
    /// can update every minute without dragging more conservative providers along for the ride.
    func refreshDueProviders() async {
        await refreshBatch(providerIDs: dueProviderIDs(at: now()), force: false)
    }

    private func refreshBatch(providerIDs: [String], force: Bool) async {
        guard !providerIDs.isEmpty else { return }
        // `Task {}` from MainActor context inherits the isolation (a task-group child can't capture
        // the non-Sendable store), so: fire one task per provider, then await them all.
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

    func dueProviderIDs(at date: Date) -> [String] {
        registry.providers.map(\.id).filter { providerID in
            guard isProviderEnabled(providerID) else { return false }
            guard !refreshingProviderIDs.contains(providerID) else { return false }
            return (nextProbeAtByProvider[providerID] ?? date) <= date
        }
    }

    func nextScheduledRefreshDate(at date: Date? = nil) -> Date? {
        let reference = date ?? now()
        return registry.providers.map(\.id)
            .filter { isProviderEnabled($0) }
            .map { nextProbeAtByProvider[$0] ?? reference }
            .min()
    }

    /// What a single provider's refresh actually did this pass, so `refreshAll` can summarize the batch
    /// from real outcomes rather than cumulative error state. `.backedOff` is a probe deliberately skipped
    /// because the provider is waiting out its failure backoff — distinct from `.skipped` (disabled /
    /// unknown / already in flight) so a wake-burst's suppression is visible in the logs.
    enum RefreshOutcome: Sendable { case refreshed, failed, cacheHit, skipped, backedOff }

    @discardableResult
    func refresh(providerID: String, force: Bool = false) async -> RefreshOutcome {
        guard isProviderEnabled(providerID) else { return .skipped }
        let baseInterval = ProviderRefreshPolicy.baseInterval(for: providerID)
        // A provider that just failed or was rate-limited isn't cached as a healthy success, so hold off
        // until its scheduled retry. The manual `force` refresh ignores this deadline.
        if !force,
           consecutiveFailures[providerID, default: 0] > 0,
           let retryAfter = nextProbeAtByProvider[providerID],
           now() < retryAfter {
            let remaining = Int(ceil(retryAfter.timeIntervalSince(now())))
            AppLog.debug(.refresh, "backoff skip \(providerID) (\(remaining)s remaining)")
            return .backedOff
        }
        if !force, let cached = cache.snapshot(providerID: providerID, ttl: baseInterval) {
            // Skip the no-op write: `@Observable` doesn't compare values, so unconditionally
            // re-assigning an unchanged snapshot would re-render the menu-bar label every pass.
            AppLog.debug(.refresh, "cache hit \(providerID)")
            if snapshots[providerID] != cached {
                snapshots[providerID] = cached
            }
            scheduleSuccess(for: providerID, from: cached.refreshedAt)
            return .cacheHit
        }
        if !force { AppLog.debug(.refresh, "cache miss \(providerID)") }

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
            scheduleFailure(for: providerID, retryAfter: snapshot.retryAfter)
            AppLog.warn(.refresh, "\(providerID) failed: \(message)")
            return .failed
        }
        if let retryAfter = snapshot.retryAfter {
            providerErrors[providerID] = nil
            scheduleFailure(for: providerID, retryAfter: retryAfter)
            snapshots[providerID] = snapshot
            AppLog.warn(.refresh, "\(providerID) asked to retry later")
            return .failed
        }
        if providerErrors[providerID] != nil {
            providerErrors[providerID] = nil
        }
        scheduleSuccess(for: providerID, from: now())
        snapshots[providerID] = snapshot
        cache.store(snapshot)
        AppLog.info(.refresh, "\(providerID) ok (\(durationMs)ms)")
        return .refreshed
    }

    /// Clears a provider's failure backoff so the next pass probes it immediately. Called when the user
    /// re-enables a provider: the enablement wake exists to fetch promptly, so a stale backoff from a
    /// failure just before it was turned off must not suppress that fetch (the loop wouldn't otherwise
    /// retry until the 5-minute heartbeat). The periodic loop never calls this — only the user action does.
    func clearFailureBackoff(for providerID: String) {
        consecutiveFailures[providerID] = nil
        effectiveRefreshIntervals[providerID] = ProviderRefreshPolicy.baseInterval(for: providerID)
        nextProbeAtByProvider[providerID] = nil
    }

    private func scheduleSuccess(for providerID: String, from date: Date) {
        let interval = ProviderRefreshPolicy.baseInterval(for: providerID)
        consecutiveFailures[providerID] = nil
        effectiveRefreshIntervals[providerID] = interval
        nextProbeAtByProvider[providerID] = date.addingTimeInterval(interval)
    }

    private func scheduleFailure(for providerID: String, retryAfter: Date?) {
        let failureCount = consecutiveFailures[providerID, default: 0] + 1
        consecutiveFailures[providerID] = failureCount

        let baseInterval = ProviderRefreshPolicy.baseInterval(for: providerID)
        var delay = ProviderRefreshPolicy.failureBackoff(
            consecutiveFailures: failureCount,
            baseInterval: baseInterval
        )
        if let retryAfter {
            delay = max(delay, retryAfter.timeIntervalSince(now()))
        }
        effectiveRefreshIntervals[providerID] = delay
        nextProbeAtByProvider[providerID] = now().addingTimeInterval(delay)
    }

    /// The provider's latest refresh error, or `nil` when its last refresh succeeded.
    func errorMessage(for providerID: String) -> String? {
        providerErrors[providerID]
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
    static let stalenessThreshold = ProviderRefreshPolicy.defaultBaseInterval * stalenessCycleCount

    func stalenessThreshold(for providerID: String) -> TimeInterval {
        let effectiveInterval = effectiveRefreshIntervals[providerID]
            ?? ProviderRefreshPolicy.baseInterval(for: providerID)
        return ProviderRefreshPolicy.stalenessThreshold(effectiveInterval: effectiveInterval)
    }

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
        guard age >= stalenessThreshold(for: providerID),
              let duration = Formatters.compactDuration(age) else {
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
        case .values(_, let values, _, let expiriesAt):
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

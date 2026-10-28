import Foundation
import Observation

@MainActor
@Observable
final class WidgetDataStore {
    @ObservationIgnored private var registry: WidgetRegistry
    @ObservationIgnored private var providersByID: [String: ProviderRuntime]
    private let cache: ProviderSnapshotCache
    private let defaults: UserDefaults
    /// The user's widget order that drives the menu-bar value. Injected
    /// so the store reads `LayoutStore.visiblePlaced` without owning it; defaults to registry order.
    private let layoutOrderedDescriptors: (@MainActor () -> [WidgetDescriptor])?
    /// Clock for the failure backoff and staleness. Injected so tests can advance time deterministically.
    private let now: () -> Date
    /// Monotonic clock for refresh durations, kept separate from wall time so a clock adjustment cannot
    /// produce a negative or wildly inflated provider timing. Tests inject exact ticks.
    private let monotonicNow: () -> TimeInterval
    private let slowProviderRefreshThreshold: TimeInterval
    /// See `defaultProviderRefreshTimeout`. Injected so tests can drive the deadline in milliseconds.
    private let providerRefreshTimeout: TimeInterval
    /// The cadence expected after a fetch, stamped on each good snapshot as `nextRefreshAt`. Injected so
    /// tests don't read this Mac's idle time.
    private let expectedRefreshInterval: () -> TimeInterval
    /// Quota-notification preferences (three independent triggers). Injected; `nil` disables
    /// notifications entirely (tests and previews that don't wire it).
    private let notificationSettings: (@MainActor () -> NotificationSettingsStore)?
    /// Where a fired milestone is delivered: `(idPrefix, title, subtitle, body) -> Bool`. The Bool is
    /// whether it was actually delivered (authorized + scheduled); on false the caller leaves the
    /// milestone un-marked so it retries next pass. Injected so tests can record posts without a live
    /// notification center; defaults to the shared `AppNotifications`.
    private let postNotification: @MainActor (String, String, String, String) async -> Bool

    private static let meterStyleKey = "meterStyle"
    private static let resetDisplayModeKey = "resetDisplayMode"
    static let defaultSlowProviderRefreshThreshold: TimeInterval = 10
    /// Hard deadline for a single account's `refresh()` call. If it hasn't returned by then
    /// the refresh is cancelled, the spinner stops, and the failure is surfaced like any other error.
    ///
    /// This is a last-resort backstop, not a latency budget. Keep it above the combined per-request
    /// timeouts for providers that make several sequential API requests; slowness short of the deadline
    /// is reported separately by `slowProviderRefreshThreshold`.
    static let defaultProviderRefreshTimeout: TimeInterval = 120

    /// The last good snapshot per account: the cached one at launch, replaced as refreshes land.
    var snapshots: [String: ProviderSnapshot] = [:]
    /// The refresh in flight per account. Owning the task is what lets `apply` cancel a removed
    /// account's work; the keys drive the dashboard's spinners.
    private var inFlight: [String: Task<ProviderSnapshot?, Never>] = [:]
    var refreshingProviderIDs: Set<String> { Set(inFlight.keys) }
    /// Wall-clock time the most recent full refresh pass finished. Together with the chosen refresh
    /// cadence it drives the dashboard footer's live "Next update in …" countdown, so the footer reflects
    /// the real schedule instead of a hardcoded value. `nil` until the first pass completes.
    var lastRefreshAt: Date?
    /// Latest refresh error per account. Set when
    /// a refresh comes back as an error snapshot, cleared on the next successful one. The dashboard
    /// renders it as a warning indicator beside the provider name; the last good snapshot keeps
    /// displaying (stale-while-revalidate) instead of being replaced by dead "No data" rows.
    var providerErrors: [String: String] = [:]

    /// The wait after a failed refresh, per account (see `RefreshBackoff`). A failed refresh isn't
    /// cached, so this is what keeps a broken account from being asked on every pass. Observed, because
    /// the account's clock glyph names the time a provider-set wait ends.
    private(set) var backoffs: [String: RefreshBackoff] = [:]
    /// When each account's last real fetch started, so a manual refresh skips one fetched moments ago.
    @ObservationIgnored private var lastFetchAt: [String: Date] = [:]

    /// Owns the quota pace-notification subsystem (dedup state, fire/deliver decision, trace). This store
    /// gathers each pass's visible bounded metrics and delegates.
    @ObservationIgnored private let notificationEvaluator = QuotaNotificationEvaluator()

    /// Global meter style: whether every bounded row (and the menu-bar value) renders as "used" or
    /// "left/remaining". Persisted so the choice survives relaunch; defaults to `.remaining`.
    var meterStyle: WidgetDisplayMode {
        didSet { defaults.set(meterStyle.rawValue, forKey: Self.meterStyleKey) }
    }

    /// What a real provider fetch came back with. Cache hits, skips, and backoffs are timer noise and
    /// never reach `onRefreshOutcome`.
    enum FetchResult: Sendable, Equatable { case refreshed, failed }

    /// Telemetry hook wired by `AppContainer`: `(providerID, result, manual)`, once per real fetch, so
    /// the recorder can roll daily success and failure counts up into one event per provider per day.
    /// `nil` (and so a no-op) in tests and previews. Not observable UI state.
    @ObservationIgnored var onRefreshOutcome: (@MainActor (String, FetchResult, Bool) -> Void)?

    /// Global reset-countdown format: relative ("Resets in 4d 17h") or absolute ("Resets tomorrow at
    /// 9:00 AM"). Persisted across relaunch; defaults to `.relative`. Toggled by clicking a reset label.
    var resetDisplayMode: ResetDisplayMode {
        didSet { defaults.set(resetDisplayMode.rawValue, forKey: Self.resetDisplayModeKey) }
    }

    init(
        registry: WidgetRegistry,
        providers: [ProviderRuntime],
        cache: ProviderSnapshotCache = ProviderSnapshotCache(),
        defaults: UserDefaults = .standard,
        orderedDescriptors: (@MainActor () -> [WidgetDescriptor])? = nil,
        now: @escaping () -> Date = Date.init,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        slowProviderRefreshThreshold: TimeInterval = WidgetDataStore.defaultSlowProviderRefreshThreshold,
        providerRefreshTimeout: TimeInterval = WidgetDataStore.defaultProviderRefreshTimeout,
        notificationSettings: (@MainActor () -> NotificationSettingsStore)? = nil,
        postNotification: (@MainActor (String, String, String, String) async -> Bool)? = nil,
        expectedRefreshInterval: @escaping () -> TimeInterval = { RefreshSetting.interval }
    ) {
        precondition(slowProviderRefreshThreshold >= 0)
        precondition(providerRefreshTimeout > 0)
        self.registry = registry
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        self.cache = cache
        self.defaults = defaults
        self.layoutOrderedDescriptors = orderedDescriptors
        self.now = now
        self.monotonicNow = monotonicNow
        self.slowProviderRefreshThreshold = slowProviderRefreshThreshold
        self.providerRefreshTimeout = providerRefreshTimeout
        self.expectedRefreshInterval = expectedRefreshInterval
        self.notificationSettings = notificationSettings
        self.postNotification = postNotification
            ?? { idPrefix, title, subtitle, body in
                await AppNotifications.shared.post(idPrefix: idPrefix, title: title, subtitle: subtitle, body: body)
            }
        self.meterStyle = defaults.enumValue(forKey: Self.meterStyleKey, default: .remaining)
        self.resetDisplayMode = defaults.enumValue(forKey: Self.resetDisplayModeKey, default: .relative)
        // Stale-while-revalidate: load whatever was cached (expired included) so the menu bar and
        // dashboard show last-known values immediately at launch instead of "—"; the refresh loop
        // replaces them as soon as fresh data lands.
        self.snapshots = cache.loadSnapshots(providerIDs: registry.providers.map(\.id))
    }

    /// Adopts a new set of account runtimes in place. A removed account's refresh is cancelled and its
    /// data dropped from the store and the cache, a new account shows its cached snapshot (if any)
    /// until its first refresh lands, and accounts that are still present keep their snapshots untouched.
    func apply(providers: [ProviderRuntime], registry: WidgetRegistry) {
        self.registry = registry
        providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        let ids = Set(providersByID.keys)
        for (id, task) in inFlight where !ids.contains(id) { task.cancel() }
        inFlight = inFlight.filter { ids.contains($0.key) }
        cache.remove(providerIDs: Set(snapshots.keys).subtracting(ids))
        var next = snapshots.filter { ids.contains($0.key) }
        let added = ids.subtracting(next.keys)
        for (cardID, snapshot) in cache.loadSnapshots(providerIDs: Array(added)) { next[cardID] = snapshot }
        snapshots = next
        providerErrors = providerErrors.filter { ids.contains($0.key) }
        backoffs = backoffs.filter { ids.contains($0.key) }
        lastFetchAt = lastFetchAt.filter { ids.contains($0.key) }
    }

    /// Refresh every account, concurrently — one slow provider never delays the rest.
    /// Everything stays MainActor-isolated; the overlap happens at the network awaits inside each
    /// provider, and the per-provider in-flight guard in `refresh` still prevents duplicate fetches.
    /// `force` bypasses the snapshot cache and the client's own failure backoff (the manual "refresh now"
    /// path), never a wait the provider set; the periodic loop honors all three.
    func refreshAll(force: Bool = false) async {
        await refreshPass(registry.providers.map(\.id), force: force)
    }

    /// ⌘R, the footer, and the Refresh menu items: every account (or just `providerIDs`) that wasn't
    /// fetched in the last `RefreshSetting.manualRefreshMinimum`, skipping the cache and the client's own
    /// failure backoff but never a wait the provider set. Mashing ⌘R asks each provider once.
    func refreshManually(providerIDs: [String]? = nil) async {
        let due = (providerIDs ?? registry.providers.map(\.id)).filter { id in
            lastFetchAt[id].map { now().timeIntervalSince($0) >= RefreshSetting.manualRefreshMinimum } ?? true
        }
        guard !due.isEmpty else {
            AppLog.debug(.refresh, "manual refresh skipped; every account was fetched in the last \(Int(RefreshSetting.manualRefreshMinimum))s")
            return
        }
        if providerIDs == nil {
            await refreshPass(due, force: true)
        } else {
            await refresh(providerIDs: due, force: true)
        }
    }

    /// Refreshes every account whose numbers are older than `age`, or that has none, honouring the cache
    /// and every backoff like a scheduled pass.
    func refreshStale(olderThan age: TimeInterval) async {
        let stale = registry.providers.map(\.id).filter { id in
            snapshots[id].map { now().timeIntervalSince($0.refreshedAt) > age } ?? true
        }
        guard !stale.isEmpty else { return }
        await refresh(providerIDs: stale, force: false)
    }

    private func refreshPass(_ providerIDs: [String], force: Bool) async {
        let start = monotonicNow()
        AppLog.notice(.refresh, "batch start (\(providerIDs.count) providers, force=\(force))")
        let outcomes = await refresh(providerIDs: providerIDs, force: force)
        // Stamp the end of the pass so the footer countdown targets the next scheduled refresh
        // (this time + one refresh interval), mirroring the periodic loop that sleeps one interval
        // after each pass.
        lastRefreshAt = Date()
        let durationMs = durationMilliseconds(since: start)
        // Count THIS batch's actual outcomes, not the long-lived `providerErrors` map (which persists
        // across passes, so reading it would miscount cache hits and stale earlier failures).
        let refreshed = outcomes.count { $0 == .refreshed }
        let failed = outcomes.count { $0 == .failed }
        let cached = outcomes.count { $0 == .cacheHit }
        let backedOff = outcomes.count { $0 == .backedOff }
        AppLog.notice(.refresh, "batch end (\(durationMs)ms, \(refreshed) ok / \(failed) failed / \(cached) cached / \(backedOff) backed off)")
    }

    /// Refreshes these accounts side by side, so a slow one never holds the others behind its deadline.
    /// `Task {}` from MainActor context inherits the isolation (a task-group child can't capture the
    /// non-Sendable store), so: fire one task per account, then await them all.
    @discardableResult
    func refresh(providerIDs: [String], force: Bool) async -> [RefreshOutcome] {
        let tasks = providerIDs.map { providerID in
            Task { await self.refresh(providerID: providerID, force: force) }
        }
        var outcomes: [RefreshOutcome] = []
        outcomes.reserveCapacity(tasks.count)
        for task in tasks {
            outcomes.append(await task.value)
        }
        return outcomes
    }

    /// Evaluate every visible metric for a quota pace milestone and post a notification for any
    /// that just crossed one. Driven from the periodic loop *after* `refreshAll`, so it catches pace
    /// worsening from time passing (not only from a fresh fetch). Deduped per metric per reset window by
    /// the evaluator's per-key state. No-data metrics never fire; bounded level-only metrics can fire
    /// Almost Out, but not pace-based milestones. A no-op when notifications are unconfigured
    /// (tests/previews) or all triggers are off.
    ///
    /// State for metrics not visited this pass (an account the user removed, or a metric hidden from
    /// the layout) is pruned, so adding it back starts fresh rather than carrying a stale "already
    /// fired" flag.
    func evaluateNotifications(now: Date = Date()) async {
        guard let settingsProvider = notificationSettings else { return }
        let toggles = settingsProvider().toggles
        // Gather this pass's enabled, bounded, visible metrics — unbounded rows and charts have no pace
        // story (their meterState never paces), so they're skipped here rather than occupying state.
        // Order is the layout order; the evaluator prunes state for anything not passed this pass.
        // The pass decides from this snapshot, taken before the first delivery `await`, so a mid-pass
        // refresh can't change later metrics' inputs within one pass.
        let metrics = (layoutOrderedDescriptors?() ?? registry.descriptors)
            .compactMap { descriptor -> QuotaNotificationEvaluator.Metric? in
                let data = data(for: descriptor)
                guard data.isBounded else { return nil }
                return QuotaNotificationEvaluator.Metric(
                    key: "\(descriptor.providerID).\(descriptor.id)",
                    providerID: descriptor.providerID,
                    data: data
                )
            }
        await notificationEvaluator.evaluate(
            metrics: metrics,
            toggles: toggles,
            now: now,
            providerName: { [providersByID] id in providersByID[id]?.provider.fullName ?? id },
            post: postNotification
        )
    }

    /// What a single provider's refresh actually did this pass, so `refreshAll` can summarize the batch
    /// from real outcomes rather than cumulative error state. `.backedOff` is a probe deliberately skipped
    /// because the account is waiting out a `RefreshBackoff` — distinct from `.skipped` (unknown /
    /// already in flight) so the suppression is visible in the logs.
    enum RefreshOutcome: Sendable { case refreshed, failed, cacheHit, skipped, backedOff }

    /// Refresh one account; a fetched snapshot is cached as it lands.
    @discardableResult
    func refresh(providerID: String, force: Bool = false) async -> RefreshOutcome {
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

        // A failed account isn't cached, so nothing else stops the loop from asking it again on every
        // pass. Hold off until its backoff ends. The manual `force` refresh skips the client's own
        // backoff but never asks before a wait the provider set.
        if let backoff = backoffs[providerID], now() < backoff.retryAt, backoff.providerAsked || !force {
            AppLog.debug(.refresh, "backoff skip \(providerID) (\(Int(backoff.retryAt.timeIntervalSince(now())))s left)")
            return .backedOff
        }

        guard let provider = providersByID[providerID] else { return .skipped }
        // Skip if an in-flight refresh already owns this provider (e.g. the background timer racing the
        // first popover open), so we never fire duplicate network calls for the same provider.
        guard inFlight[providerID] == nil else {
            AppLog.debug(.refresh, "cache skip \(providerID) (already in flight)")
            return .skipped
        }
        let start = monotonicNow()
        lastFetchAt[providerID] = now()
        // A provider that never returns would otherwise hold the in-flight entry — and the spinner —
        // forever. Past the deadline, stop waiting and treat it as any other failed refresh.
        let work = Task { [providerRefreshTimeout] in
            await ProviderRefreshDeadline.snapshot(from: provider, timeout: providerRefreshTimeout)
        }
        inFlight[providerID] = work
        defer { if inFlight[providerID] == work { inFlight[providerID] = nil } }
        let result = await work.value
        // The account may have been removed while this was in flight. Its runtime is gone from
        // `providersByID` then, and nothing from the late result is published, cached, or counted.
        guard providersByID[providerID] === provider else {
            AppLog.debug(.refresh, "dropped \(providerID) refresh; the account was removed")
            return .skipped
        }
        guard var snapshot = result else {
            let message = "Refresh timed out after \(Int(providerRefreshTimeout))s"
            return recordFailure(RefreshFailure(message: message, kind: .refused), providerID: providerID, force: force)
        }
        // A canceled refresh may still return if a provider's underlying work is non-throwing. Never
        // publish that potentially partial snapshot; keep the last-good state exactly as it was.
        guard !Task.isCancelled else {
            AppLog.debug(.refresh, "cancelled \(providerID) refresh; keeping last-good snapshot")
            return .skipped
        }
        let durationMs = durationMilliseconds(since: start)
        if TimeInterval(durationMs) >= slowProviderRefreshThreshold * 1000 {
            AppLog.warn(
                .refresh,
                "\(providerID) slow refresh (\(durationMs)ms, threshold=\(Int(slowProviderRefreshThreshold * 1000))ms)"
            )
        }
        if let failure = snapshot.failure {
            return recordFailure(failure, providerID: providerID, force: force)
        }
        if providerErrors[providerID] != nil {
            providerErrors[providerID] = nil
        }
        // Recovered: drop any backoff so the account resumes the normal cadence immediately.
        if backoffs[providerID] != nil { backoffs[providerID] = nil }
        snapshot.nextRefreshAt = snapshot.refreshedAt.addingTimeInterval(expectedRefreshInterval())
        snapshots[providerID] = snapshot
        cache.store(snapshot)
        AppLog.info(.refresh, "\(providerID) ok (\(durationMs)ms)")
        onRefreshOutcome?(providerID, .refreshed, force)
        return .refreshed
    }

    /// A failed refresh keeps the last good snapshot on screen rather than collapsing every row to
    /// "No data", and backs the account off. A wait the provider set shows as the clock glyph with the
    /// time it ends; any other failure raises the warning with the provider's user-safe message.
    private func recordFailure(_ failure: RefreshFailure, providerID: String, force: Bool) -> RefreshOutcome {
        let backoff = RefreshBackoff.after(failure.kind, previous: backoffs[providerID], now: now())
        backoffs[providerID] = backoff
        let notice = backoff.providerAsked ? nil : failure.message
        if providerErrors[providerID] != notice { providerErrors[providerID] = notice }
        let wait = Int(backoff.retryAt.timeIntervalSince(now()))
        AppLog.warn(.refresh, "\(providerID) failed: \(failure.message) Next try in \(wait)s.")
        onRefreshOutcome?(providerID, .failed, force)
        return .failed
    }

    private func durationMilliseconds(since start: TimeInterval) -> Int {
        max(0, Int((monotonicNow() - start) * 1000))
    }

    /// The provider's latest refresh error, or `nil` when its last refresh succeeded.
    func errorMessage(for providerID: String) -> String? {
        providerErrors[providerID]
    }


    func data(for descriptor: WidgetDescriptor) -> WidgetData {
        var result: WidgetData
        if let snapshot = snapshots[descriptor.providerID],
           let line = snapshot.line(label: descriptor.metricLabel),
           let data = resolve(line, descriptor: descriptor) {
            result = data
        } else {
            // No real metric line backs this placed row, so the sample's numbers are placeholders.
            // Flag it as no-data; the row renders "No data" instead of inventing usage.
            result = descriptor.sample
            result.hasData = false
        }

        // Single global choke point: dashboard/share rows and menu-bar values all funnel through here,
        // so stamping the mode once makes them follow the global setting. Inert for unbounded rows
        // (limit == nil), whose displayed value ignores displayMode.
        result.displayMode = meterStyle
        result.resetDisplayMode = resetDisplayMode
        return result
    }

    /// The plan label for a provider's latest snapshot. `nil` until a snapshot exists or when the
    /// provider doesn't expose a plan. Provider section headers render this beside the provider name.
    func plan(for providerID: String) -> String? {
        snapshots[providerID]?.plan
    }

    /// How long a displayed snapshot may age before the header calls it out. A healthy provider's
    /// snapshot resets to ~0 on every successful pass and only brushes one interval just before the next
    /// one, so the threshold sits at two intervals: it fires only when a refresh has actually been missed
    /// — a refresh loop that keeps failing, or a long-suspended background timer — never on the normal
    /// per-cycle aging, which would flicker a hint on healthy providers.
    static let stalenessThreshold = RefreshSetting.interval * 2

    /// How old the provider's on-screen snapshot is ("Last updated 3h 12m ago"), once it has aged past
    /// `stalenessThreshold`; `nil` while the data is still current (the common case), so the account's
    /// name stays clean until staleness is real. The clock glyph after the name shows while this is set,
    /// and the right-click menu opens with it. This is the visible counterpart to the silent
    /// fossilized-cache problem: a failing-refresh loop keeps the last good plan/limits on screen, and
    /// without this nothing told the user that data was stale. Reads the store's injected clock, which
    /// tests pin to a fixed value.
    ///
    /// While the provider has asked OpenUsage to wait (a 429), the glyph says so and names the time the
    /// account is asked again, whatever the numbers' age.
    func stalenessHint(for providerID: String) -> String? {
        if let backoff = backoffs[providerID], backoff.providerAsked, now() < backoff.retryAt {
            let name = providersByID[providerID]?.provider.displayName ?? "The provider"
            return "\(name) asked OpenUsage to wait. Retrying at \(Formatters.compactClock(backoff.retryAt, now: now()))."
        }
        guard let refreshedAt = snapshots[providerID]?.refreshedAt else { return nil }
        let age = now().timeIntervalSince(refreshedAt)
        guard age >= Self.stalenessThreshold, let duration = Formatters.compactDuration(age) else {
            return nil
        }
        return "Last updated \(duration) ago"
    }

    private func resolve(_ line: MetricLine, descriptor: WidgetDescriptor) -> WidgetData? {
        switch line {
        case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs):
            // A percent meter is a bounded 0...100 domain; sanitize an out-of-range sample (a provider
            // reporting a negative or >100 utilization) here, at the single construction choke point
            // every provider funnels through, so no surface — the row, the menu bar — can
            // render "-5%" or "105%". For percent the limit is always 100, so clamping `used` also
            // keeps the meter's spent verdict intact (>=100 still reads spent). Non-percent
            // meters keep their raw `used`: a dollar/count overage (used > limit) is real and is
            // conveyed by the meter's spent state rather than hidden.
            let normalizedUsed = format == .percent ? ProviderParse.clampPercent(used) : used
            var result = WidgetData(
                title: descriptor.sample.title,
                kind: format.metricKind,
                used: normalizedUsed,
                limit: limit,
                resetsAt: resetsAt,
                periodDurationMs: periodDurationMs
            )
            // Descriptor opt-in (an unused session window shows a full bar and no reset); the fresh
            // `.progress` result doesn't start from the sample, so carry the signal explicitly.
            result.sessionStartSignal = descriptor.sample.sessionStartSignal
            return result
        case .values(_, let values, let expiriesAt):
            // The number is carried raw — no regex re-parse. Presentation (title, icon, trailing word)
            // comes from the descriptor's sample; the live numbers come from the line.
            var data = descriptor.sample
            data.values = values
            // A `.values` line is unbounded by definition (see `MetricLine`), so it never renders as a
            // meter even when the descriptor template carries a placeholder limit — e.g. Claude's
            // `claude.extra` is `boundedDollars` for its capped `.progress` case but feeds an uncapped
            // `.values` row when there's no monthly cap.
            data.limit = nil
            // Optional expiry instants (Claude and Codex rate-limit resets): listed in the row's hover
            // popover, which formats them live against the clock.
            data.expiriesAt = expiriesAt
            data.hasData = !data.values.isEmpty
            return data
        case .badge(_, let text):
            var data = descriptor.sample
            data.valueTextOverride = text
            return data
        }
    }

}

import Foundation
import Observation

@MainActor
@Observable
final class WidgetDataStore {
    @ObservationIgnored private var registry: WidgetRegistry
    @ObservationIgnored private var providersByID: [String: ProviderRuntime]
    private let cache: ProviderSnapshotCache
    private let defaults: UserDefaults
    /// Clock for the failure backoff and staleness. Injected so tests can advance time deterministically.
    private let now: () -> Date
    /// See `defaultProviderRefreshTimeout`. Injected so tests can drive the deadline in milliseconds.
    private let providerRefreshTimeout: TimeInterval

    private static let meterStyleKey = "meterStyle"
    private static let resetDisplayModeKey = "resetDisplayMode"
    private static let slowProviderRefreshThreshold: TimeInterval = 10
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

    /// Global meter style: whether every bounded row (and the menu-bar value) renders as "used" or
    /// "left/remaining". Persisted so the choice survives relaunch; defaults to `.remaining`.
    var meterStyle: WidgetDisplayMode {
        didSet { defaults.set(meterStyle.rawValue, forKey: Self.meterStyleKey) }
    }

    /// Telemetry hook wired by `AppContainer`: `(kind, outcome, manual)`, once per real fetch
    /// (`.refreshed` or `.failed`; cache hits, skips, and backoffs are timer noise and never reach it), so
    /// the recorder can roll daily success and failure counts up into one event per provider per day.
    /// `nil` (and so a no-op) in tests and previews. Not observable UI state.
    @ObservationIgnored var onRefreshOutcome: (@MainActor (ProviderKind, RefreshOutcome, Bool) -> Void)?

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
        now: @escaping () -> Date = Date.init,
        providerRefreshTimeout: TimeInterval = WidgetDataStore.defaultProviderRefreshTimeout,
    ) {
        precondition(providerRefreshTimeout > 0)
        self.registry = registry
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        self.cache = cache
        self.defaults = defaults
        self.now = now
        self.providerRefreshTimeout = providerRefreshTimeout
        self.meterStyle = defaults.enumValue(forKey: Self.meterStyleKey, default: .remaining)
        self.resetDisplayMode = defaults.enumValue(forKey: Self.resetDisplayModeKey, default: .relative)
        // Stale-while-revalidate: load whatever was cached (expired included) so the menu bar and
        // dashboard show last-known values immediately at launch instead of "—"; the refresh loop
        // replaces them as soon as fresh data lands.
        let ids = Set(registry.providers.map(\.id))
        self.snapshots = cache.load().filter { ids.contains($0.key) }
        for (id, snapshot) in snapshots { providersByID[id]?.restore(snapshot) }
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
        var next = snapshots.filter { ids.contains($0.key) }
        let removed = next.count < snapshots.count
        let added = ids.subtracting(next.keys)
        for (cardID, snapshot) in cache.load() where added.contains(cardID) {
            next[cardID] = snapshot
            providersByID[cardID]?.restore(snapshot)
        }
        snapshots = next
        if removed { cache.save(next) }
        providerErrors = providerErrors.filter { ids.contains($0.key) }
        backoffs = backoffs.filter { ids.contains($0.key) }
    }

    /// Refresh every account, concurrently — one slow provider never delays the rest.
    /// Everything stays MainActor-isolated; the overlap happens at the network awaits inside each
    /// provider, and the per-provider in-flight guard in `refresh` still prevents duplicate fetches.
    /// `force` (⌘R, the footer) bypasses the snapshot cache, each account's hourly reads and the client's
    /// own failure backoff, never a wait the provider set; the periodic loop honors all of them.
    func refreshAll(force: Bool = false) async {
        await refreshPass(registry.providers.map(\.id), force: force)
    }

    private func refreshPass(_ providerIDs: [String], force: Bool) async {
        let start = ProcessInfo.processInfo.systemUptime
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
    /// non-Sendable store), so: fire one task per account, then await them all. A forced batch (⌘R, the
    /// Refresh menu item) also asks each account's hourly reads again.
    @discardableResult
    func refresh(providerIDs: [String], force: Bool) async -> [RefreshOutcome] {
        let tasks = providerIDs.map { providerID in
            Task { await self.refresh(providerID: providerID, force: force, rereadHourly: force) }
        }
        var outcomes: [RefreshOutcome] = []
        outcomes.reserveCapacity(tasks.count)
        for task in tasks {
            outcomes.append(await task.value)
        }
        return outcomes
    }


    /// What a single provider's refresh actually did this pass, so `refreshAll` can summarize the batch
    /// from real outcomes rather than cumulative error state. `.backedOff` is a probe deliberately skipped
    /// because the account is waiting out a `RefreshBackoff` — distinct from `.skipped` (unknown /
    /// already in flight) so the suppression is visible in the logs.
    enum RefreshOutcome: Sendable { case refreshed, failed, cacheHit, skipped, backedOff }

    /// Refresh one account; a fetched snapshot is cached as it lands. `rereadHourly` asks its hourly reads
    /// again first, which a claim's or a new account's forced refresh doesn't.
    @discardableResult
    func refresh(providerID: String, force: Bool = false, rereadHourly: Bool = false) async -> RefreshOutcome {
        // Fresh means fetched less than one interval ago, across a relaunch too. A clock that went
        // backwards never makes a snapshot fresh.
        if !force, let shown = snapshots[providerID],
           (0..<RefreshSetting.interval).contains(now().timeIntervalSince(shown.refreshedAt)) {
            AppLog.debug(.refresh, "cache hit \(providerID)")
            return .cacheHit
        }
        if !force { AppLog.debug(.refresh, "cache miss \(providerID)") }

        // A failed account isn't cached, so nothing else stops the loop from asking it again on every
        // pass. Hold off until its backoff ends; `RefreshBackoff.holds` says whether a forced refresh
        // waits too.
        if let backoff = backoffs[providerID], backoff.holds(at: now(), forced: force) {
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
        if rereadHourly { provider.forgetHourlyReads() }
        let start = ProcessInfo.processInfo.systemUptime
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
        guard let snapshot = result else {
            let message = "Refresh timed out after \(Int(providerRefreshTimeout))s"
            return recordFailure(RefreshFailure(message: message, kind: .refused), providerID: providerID, kind: provider.provider.kind, force: force)
        }
        // A canceled refresh may still return if a provider's underlying work is non-throwing. Never
        // publish that potentially partial snapshot; keep the last-good state exactly as it was.
        guard !Task.isCancelled else {
            AppLog.debug(.refresh, "cancelled \(providerID) refresh; keeping last-good snapshot")
            return .skipped
        }
        let durationMs = durationMilliseconds(since: start)
        if TimeInterval(durationMs) >= Self.slowProviderRefreshThreshold * 1000 {
            AppLog.warn(
                .refresh,
                "\(providerID) slow refresh (\(durationMs)ms, threshold=\(Int(Self.slowProviderRefreshThreshold * 1000))ms)"
            )
        }
        if let failure = snapshot.failure {
            return recordFailure(failure, providerID: providerID, kind: provider.provider.kind, force: force)
        }
        if providerErrors[providerID] != nil {
            providerErrors[providerID] = nil
        }
        // Recovered: drop any backoff so the account resumes the normal cadence immediately.
        if backoffs[providerID] != nil { backoffs[providerID] = nil }
        snapshots[providerID] = snapshot
        cache.save(snapshots)
        AppLog.info(.refresh, "\(providerID) ok (\(durationMs)ms)")
        onRefreshOutcome?(provider.provider.kind, .refreshed, force)
        return .refreshed
    }

    /// The secondary-reads slot, halfway between passes: each account with a snapshot on screen, one at a
    /// time, makes the reads its runtime keeps out of a pass, and its card shows the answer now rather than
    /// a pass later. An account that is refreshing or waiting out a backoff is left for the next slot, and
    /// an answer that a refresh overtook is dropped, since the next pass carries it.
    func refreshHourlyReads() async {
        for id in registry.providers.map(\.id) {
            guard let provider = providersByID[id], inFlight[id] == nil, let snapshot = snapshots[id],
                  backoffs[id]?.holds(at: now(), forced: false) != true
            else { continue }
            guard let updated = await provider.refreshHourlyReads(of: snapshot),
                  providersByID[id] === provider, snapshots[id] == snapshot
            else { continue }
            snapshots[id] = updated
            cache.save(snapshots)
        }
    }

    /// A failed refresh keeps the last good snapshot on screen rather than collapsing every row to
    /// "No data", and backs the account off. A wait the provider set shows as the clock glyph with the
    /// time it ends; any other failure raises the warning with the provider's user-safe message.
    private func recordFailure(_ failure: RefreshFailure, providerID: String, kind: ProviderKind, force: Bool) -> RefreshOutcome {
        let backoff = RefreshBackoff.after(failure.kind, previous: backoffs[providerID], now: now())
        backoffs[providerID] = backoff
        let notice = backoff.providerAsked ? nil : failure.message
        if providerErrors[providerID] != notice { providerErrors[providerID] = notice }
        let wait = Int(backoff.retryAt.timeIntervalSince(now()))
        AppLog.warn(.refresh, "\(providerID) failed: \(failure.message) Next try in \(wait)s.")
        onRefreshOutcome?(kind, .failed, force)
        return .failed
    }

    private func durationMilliseconds(since start: TimeInterval) -> Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
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
            // No real metric line backs this shown row, so the sample's numbers are placeholders.
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

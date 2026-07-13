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
    /// Every runtime the refresh loop drives, grouped by provider: the default account's runtime
    /// plus one scoped runtime per extra account. A provider without extra accounts has exactly one
    /// entry — the pre-accounts behavior, unchanged. `var` because post-launch account discovery
    /// registers runtimes for newly found accounts (see `registerAccountRuntime`).
    private var accountRuntimesByProvider: [String: [AccountRuntime]]
    /// Which account's snapshot the provider's card (and menu-bar pins) currently shows — the bare
    /// provider id for the default account. Injected from `ProviderAccountsStore`; defaults to
    /// "always the default account" for tests, previews, and the one-shot CLI reader.
    private let selectedAccountKey: @MainActor (String) -> String
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
    private static let alwaysShowPacingKey = "alwaysShowPacing"
    /// How long a provider that just failed is skipped before the loop will probe it again. A failed
    /// refresh isn't cached, so — unlike a success, which the snapshot cache gates for an interval —
    /// nothing else stops the loop from re-probing a broken provider (logged-out Devin/Grok especially)
    /// on every wake, spawning subprocesses and network calls in a tight loop. This negative-cache caps a
    /// failing provider to one probe per window. Shorter than the refresh interval, so the normal
    /// 5-minute heartbeat always retries; it only suppresses the sub-interval re-probes a wake burst
    /// would cause. The manual `force` refresh (⌘R) always bypasses it.
    private static let failureRetryBackoff: TimeInterval = 60

    /// The snapshot each provider's card shows — always its SELECTED account's data, keyed by the
    /// bare provider id. This is the projection every view reads; the full per-account picture lives
    /// in `accountSnapshots` and is re-projected here whenever a refresh lands or the selection moves.
    var snapshots: [String: ProviderSnapshot] = [:]
    /// The latest snapshot per account key (`"<provider>"` for defaults, `"<provider>@<uuid>"` for
    /// extras). Not read by views directly — the projection above is — but kept warm for every
    /// account so switching the picker is instant.
    @ObservationIgnored private var accountSnapshots: [String: ProviderSnapshot] = [:]
    var refreshingProviderIDs: Set<String> = []
    /// Per-account in-flight guard (the dup-fetch gate); `refreshingProviderIDs` above stays the
    /// provider-level spinner state views read.
    @ObservationIgnored private var inFlightAccountKeys: Set<String> = []
    /// Wall-clock time the most recent full refresh pass finished. Together with the chosen refresh
    /// cadence it drives the dashboard footer's live "Next update in …" countdown, so the footer reflects
    /// the real schedule instead of a hardcoded value. `nil` until the first pass completes.
    var lastRefreshAt: Date?
    /// Latest refresh error per provider (e.g. "Not logged in. Run `codex` to authenticate.") — like
    /// `snapshots`, the SELECTED account's error, projected from `accountErrors`. Set when a refresh
    /// comes back as an error snapshot, cleared on the next successful one. The dashboard renders it
    /// as a warning indicator beside the provider name; the last good snapshot keeps displaying
    /// (stale-while-revalidate) instead of being replaced by dead "No data" rows.
    var providerErrors: [String: String] = [:]
    /// Latest refresh error per account key (see `accountSnapshots` for the key scheme).
    @ObservationIgnored private var accountErrors: [String: String] = [:]

    /// Per-account earliest next-probe time after a failure (see `failureRetryBackoff`). Not part of
    /// observable UI state, so it's excluded from `@Observable` tracking.
    @ObservationIgnored private var failureRetryAfter: [String: Date] = [:]

    /// Owns the quota pace-notification subsystem (dedup state, fire/deliver decision, trace). This store
    /// just gathers each pass's enabled bounded metrics and delegates.
    @ObservationIgnored private let notificationEvaluator = QuotaNotificationEvaluator()

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
        accountRuntimes: [AccountRuntime]? = nil,
        selectedAccountKey: (@MainActor (String) -> String)? = nil,
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
        // With no explicit account runtimes (tests, previews, the CLI reader), every provider runs as
        // its single default account — exactly the pre-accounts behavior.
        let runtimes = accountRuntimes
            ?? providers.map { AccountRuntime(providerID: $0.provider.id, accountKey: $0.provider.id, runtime: $0) }
        self.accountRuntimesByProvider = Dictionary(grouping: runtimes, by: \.providerID)
        self.selectedAccountKey = selectedAccountKey ?? { $0 }
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
        // replaces them as soon as fresh data lands. Loaded for every account key, then projected so
        // each card paints its selected account.
        self.accountSnapshots = cache.loadSnapshots(keys: runtimes.map(\.accountKey))
        for providerID in accountRuntimesByProvider.keys {
            let key = self.selectedAccountKey(providerID)
            if let snapshot = accountSnapshots[key] {
                self.snapshots[providerID] = snapshot
            }
        }
    }

    /// Adopt a runtime for an account that post-launch discovery just found, so it's usable
    /// immediately (picker entry, refreshes, cache) rather than after a relaunch. Idempotent per
    /// account key. Pulls any cached snapshot for the key first (stale-while-revalidate, same as
    /// init), then kicks a cache-gated refresh to warm it.
    func registerAccountRuntime(_ account: AccountRuntime) {
        var runtimes = accountRuntimesByProvider[account.providerID] ?? []
        guard !runtimes.contains(where: { $0.accountKey == account.accountKey }) else { return }
        runtimes.append(account)
        accountRuntimesByProvider[account.providerID] = runtimes
        if let cached = cache.loadSnapshots(keys: [account.accountKey])[account.accountKey] {
            accountSnapshots[account.accountKey] = cached
            projectSelection(providerID: account.providerID)
        }
        Task { await refresh(providerID: account.providerID) }
    }

    /// Swap the provider card (and its menu-bar pins) to the newly selected account: re-project the
    /// displayed snapshot/error from the per-account state, then kick a cache-gated refresh so a
    /// never-fetched account fills in promptly. Wired to `ProviderAccountsStore.onSelectionChange`.
    func applySelection(providerID: String) {
        projectSelection(providerID: providerID)
        Task { await refresh(providerID: providerID) }
    }

    /// Re-derive the provider-keyed display state (`snapshots`, `providerErrors`) from the
    /// account-keyed truth for one provider. The no-op writes are skipped: `@Observable` doesn't
    /// compare values, so blind re-assignment would re-render the menu-bar label for nothing.
    private func projectSelection(providerID: String) {
        let key = selectedAccountKey(providerID)
        if snapshots[providerID] != accountSnapshots[key] {
            snapshots[providerID] = accountSnapshots[key]
        }
        projectSelectedError(providerID: providerID)
    }

    /// The error half of the projection alone — the failed-refresh path uses this so a failure never
    /// touches the displayed snapshot (stale-while-revalidate: the last good data stays on screen
    /// under the warning triangle).
    private func projectSelectedError(providerID: String) {
        let key = selectedAccountKey(providerID)
        if providerErrors[providerID] != accountErrors[key] {
            providerErrors[providerID] = accountErrors[key]
        }
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
    /// worsening from time passing (not only from a fresh fetch). Deduped per metric per reset window by
    /// the evaluator's per-key state. No-data metrics never fire; bounded level-only metrics can fire
    /// Almost Out, but not pace-based milestones. A no-op when notifications are unconfigured
    /// (tests/previews) or all triggers are off.
    ///
    /// State for metrics not visited this pass (e.g. a provider the user just disabled, or a metric
    /// removed from the layout) is pruned, so re-enabling/re-adding starts fresh rather than carrying a
    /// stale "already fired" flag.
    func evaluateNotifications(now: Date = Date()) async {
        guard let settingsProvider = notificationSettings else { return }
        let toggles = settingsProvider().toggles
        // Gather this pass's enabled, bounded, visible metrics — unbounded rows and charts have no pace
        // story (their meterState never fires), so they're skipped here rather than occupying state.
        // Order is the layout order; the evaluator prunes state for anything not passed this pass.
        // Deliberate delta from the pre-extraction loop: the pass decides from this snapshot, taken
        // before the first delivery `await`, where the old inline loop re-read `data(for:)` between
        // deliveries — a mid-pass refresh no longer changes later metrics' inputs within one pass.
        let metrics = orderedDescriptors()
            .filter { isProviderEnabled($0.providerID) }
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
            providerName: { [providersByID] id in providersByID[id]?.provider.displayName ?? id },
            post: postNotification
        )
    }

    /// What a single provider's refresh actually did this pass, so `refreshAll` can summarize the batch
    /// from real outcomes rather than cumulative error state. `.backedOff` is a probe deliberately skipped
    /// because the provider failed within the last `failureRetryBackoff` — distinct from `.skipped`
    /// (disabled / unknown / already in flight) so a wake-burst's suppression is visible in the logs.
    enum RefreshOutcome: Sendable { case refreshed, failed, cacheHit, skipped, backedOff }

    /// Refresh every account of the provider, concurrently (each is an independent login with its own
    /// cache entry and backoff). Returns the SELECTED account's outcome — the one the card shows and
    /// callers act on (the post-claim reconcile loop, the enablement wake); the other accounts still
    /// refresh so switching the picker is instant.
    @discardableResult
    func refresh(providerID: String, force: Bool = false) async -> RefreshOutcome {
        guard isProviderEnabled(providerID) else { return .skipped }
        guard let runtimes = accountRuntimesByProvider[providerID], !runtimes.isEmpty else {
            return .skipped
        }
        let selectedKey = selectedAccountKey(providerID)
        // Fire one task per account (MainActor-inherited, like `refreshAll`), then await them all.
        let tasks = runtimes.map { runtime in
            (runtime.accountKey, Task { await self.refreshAccount(runtime, force: force) })
        }
        var selectedOutcome = RefreshOutcome.skipped
        for (key, task) in tasks {
            let outcome = await task.value
            if key == selectedKey { selectedOutcome = outcome }
        }
        return selectedOutcome
    }

    private func refreshAccount(_ account: AccountRuntime, force: Bool) async -> RefreshOutcome {
        let key = account.accountKey
        if !force, let cached = cache.snapshot(key: key) {
            AppLog.debug(.refresh, "cache hit \(key)")
            if accountSnapshots[key] != cached {
                accountSnapshots[key] = cached
                projectSelection(providerID: account.providerID)
            }
            return .cacheHit
        }
        if !force { AppLog.debug(.refresh, "cache miss \(key)") }

        // An account that just failed isn't cached, so nothing else stops the loop from re-probing it on
        // every wake. Hold off until its backoff expires; the manual `force` refresh ignores the backoff.
        if !force, let retryAfter = failureRetryAfter[key], now() < retryAfter {
            AppLog.debug(.refresh, "backoff skip \(key) (failed <\(Int(Self.failureRetryBackoff))s ago)")
            return .backedOff
        }

        // Skip if an in-flight refresh already owns this account (e.g. the background timer racing the
        // first popover open), so we never fire duplicate network calls for the same login.
        guard !inFlightAccountKeys.contains(key) else {
            AppLog.debug(.refresh, "cache skip \(key) (already in flight)")
            return .skipped
        }
        inFlightAccountKeys.insert(key)
        // The header spinner is provider-level: on while ANY of the provider's accounts is fetching.
        refreshingProviderIDs.insert(account.providerID)
        defer {
            inFlightAccountKeys.remove(key)
            let providerKeys = (accountRuntimesByProvider[account.providerID] ?? []).map(\.accountKey)
            if inFlightAccountKeys.isDisjoint(with: providerKeys) {
                refreshingProviderIDs.remove(account.providerID)
            }
        }
        let start = Date()
        // Task-local manual-refresh marker: a forced (user-initiated) refresh may show a one-time
        // keychain prompt (Claude Desktop's Safe Storage); the background timer never may.
        let snapshot = await ProviderRefreshContext.$isManual.withValue(force) {
            await account.runtime.refresh()
        }
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        if let message = Self.errorMessage(in: snapshot) {
            // Failed refresh: surface the error but keep the last good snapshot on screen rather than
            // collapsing every row to "No data". The provider error string is already user-safe.
            accountErrors[key] = message
            // Negative-cache the failure so a wake burst can't re-probe this account in a tight loop.
            failureRetryAfter[key] = now().addingTimeInterval(Self.failureRetryBackoff)
            AppLog.warn(.refresh, "\(key) failed: \(message)")
            projectSelectedError(providerID: account.providerID)
            onRefreshOutcome?(account.providerID, .failed, snapshot.errorCategory, force)
            return .failed
        }
        accountErrors[key] = nil
        // Recovered: drop any backoff so the account resumes the normal cadence immediately.
        failureRetryAfter[key] = nil
        accountSnapshots[key] = snapshot
        cache.store(snapshot, key: key)
        projectSelection(providerID: account.providerID)
        AppLog.info(.refresh, "\(key) ok (\(durationMs)ms)")
        onRefreshOutcome?(account.providerID, .refreshed, nil, force)
        return .refreshed
    }

    /// Clears a provider's failure backoff (every account's) so the next pass probes it immediately.
    /// Called when the user re-enables a provider: the enablement wake exists to fetch promptly, so a
    /// stale backoff from a failure just before it was turned off must not suppress that fetch (the
    /// loop wouldn't otherwise retry until the 5-minute heartbeat). The periodic loop never calls
    /// this — only the user action does.
    func clearFailureBackoff(for providerID: String) {
        for runtime in accountRuntimesByProvider[providerID] ?? [] {
            failureRetryAfter[runtime.accountKey] = nil
        }
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

        // Single global choke point: dashboard/share rows and menu-bar values all funnel through here,
        // so stamping the mode once makes them follow the global setting. Inert for unbounded rows
        // (limit == nil), whose displayed value ignores displayMode.
        result.displayMode = meterStyle
        result.resetDisplayMode = resetDisplayMode
        result.alwaysShowPacing = alwaysShowPacing
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
            var result = WidgetData(
                title: descriptor.sample.title,
                icon: descriptor.sample.icon,
                kind: format.metricKind,
                used: normalizedUsed,
                limit: limit,
                countSuffix: format.countSuffix,
                valuePrefix: descriptor.sample.valuePrefix,
                resetsAt: resetsAt,
                periodDurationMs: periodDurationMs,
                limitNoun: descriptor.sample.limitNoun,
                infoNote: descriptor.sample.infoNote
            )
            // Descriptor opt-in (session-window meters read "Not started" when unused); the fresh
            // `.progress` result doesn't start from the sample, so carry the flag explicitly.
            result.isSessionWindow = descriptor.sample.isSessionWindow
            return result
        case .text:
            // Text lines carry provider notices for the local API; no dashboard descriptor consumes
            // them. Numeric widgets use typed progress/values lines and must never parse display text.
            return nil
        case .values(_, let values, _, let expiriesAt, let unknownModels, let modelBreakdown):
            // The number is carried raw — no regex re-parse. Presentation (title, icon, selection,
            // trailing word) comes from the descriptor's sample; the live numbers come from the line.
            var data = descriptor.sample
            data.values = values
            // A `.values` line is unbounded by definition (see `MetricLine`), so it never renders as a
            // meter even when the descriptor template carries a placeholder limit — e.g. Claude's
            // `claude.extra` is `boundedDollars` for its capped `.progress` case but feeds an uncapped
            // `.values` row when there's no monthly cap.
            data.limit = nil
            // Optional expiry instants (Codex rate-limit-reset credits): surfaced in the row's hover
            // tooltip (see `expiryTooltip`), with the row re-rendering on the clock tick so they stay live.
            data.expiriesAt = expiriesAt
            // Unknown-model names (Cursor spend tiles): drive the label warning triangle whose hover lists
            // the models this period used that the pricing manifest can't price, so the cost is incomplete.
            data.unknownModels = unknownModels
            data.modelBreakdown = modelBreakdown
            // A tile whose selection finds no value (e.g. a cost-only tile on a day the scanner couldn't
            // price) has nothing real to show — render "No data" rather than a misleading $0.00 / 0.
            data.hasData = !data.selectedValues.isEmpty
            // The ⓘ is data-driven: it shows when a *shown* value is locally estimated (a spend row's
            // dollars) and stays off for a measured one (its tokens), so the tokens-only tile reads clean.
            data.infoNote = data.selectedValues.contains(where: \.estimated)
                ? WidgetData.localEstimateNote
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
            // axis (and so descriptor template data never leaks onto the dashboard).
            var data = descriptor.sample
            data.isChart = true
            data.chartPoints = points
            data.chartNote = note
            data.hasData = !points.isEmpty
            return data
        }
    }

}

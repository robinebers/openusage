import Foundation
import Observation

@MainActor
@Observable
final class WidgetDataStore {
    @ObservationIgnored private var registry: WidgetRegistry
    @ObservationIgnored private var providersByID: [String: ProviderRuntime]
    private let cache: ProviderSnapshotCache
    private let defaults: UserDefaults
    private let now: () -> Date
    private let providerRefreshTimeout: TimeInterval

    private static let meterStyleKey = "meterStyle"
    private static let resetDisplayModeKey = "resetDisplayMode"
    private static let menuBarLimitKey = "menuBarLimit"
    private static let menuBarAlwaysShowsKey = "menuBarAlwaysShows"
    private static let priorityWarningKey = "priorityWarning"
    private static let priorityCriticalKey = "priorityCritical"
    private static let priorityBurningFastKey = "priorityBurningFast"
    private static let priorityUseItOrLoseItKey = "priorityUseItOrLoseIt"
    private static let paceMarksKey = "paceMarks"
    private static let slowProviderRefreshThreshold: TimeInterval = 10
    static let defaultProviderRefreshTimeout: TimeInterval = 120

    var snapshots: [String: ProviderSnapshot] = [:] {
        didSet { latchBurningFast() }
    }
    private var inFlight: [String: Task<Result<ProviderSnapshot, RefreshFailure>, Never>] = [:]
    var refreshingProviderIDs: Set<String> { Set(inFlight.keys) }
    var lastRefreshAt: Date?

    private(set) var backoffs: [String: RefreshBackoff] = [:]

    var meterStyle: WidgetDisplayMode {
        didSet { defaults.set(meterStyle.rawValue, forKey: Self.meterStyleKey) }
    }

    var resetDisplayMode: ResetDisplayMode {
        didSet { defaults.set(resetDisplayMode.rawValue, forKey: Self.resetDisplayModeKey) }
    }

    var menuBarLimit: MenuBarLimit {
        didSet { defaults.set(menuBarLimit.rawValue, forKey: Self.menuBarLimitKey) }
    }

    /// The menu bar lists every Priority section in the tab's order instead of only what's running out.
    var menuBarAlwaysShows: Bool {
        didSet { defaults.set(menuBarAlwaysShows, forKey: Self.menuBarAlwaysShowsKey) }
    }

    var priorityLimits: PriorityLimits {
        didSet {
            defaults.set(priorityLimits.warning, forKey: Self.priorityWarningKey)
            defaults.set(priorityLimits.critical, forKey: Self.priorityCriticalKey)
        }
    }

    /// Priority lists limits that would run out before they reset, however much they have left.
    var showsBurningFast: Bool {
        didSet { defaults.set(showsBurningFast, forKey: Self.priorityBurningFastKey) }
    }

    /// Priority lists limits with over half left that reset within a day, the same rule as the Use It or Lose It alert.
    var showsUseItOrLoseIt: Bool {
        didSet { defaults.set(showsUseItOrLoseIt, forKey: Self.priorityUseItOrLoseItKey) }
    }

    /// Bars and Priority's rings mark where usage would be at an even pace through the window.
    var showsPaceMarks: Bool {
        didSet { defaults.set(showsPaceMarks, forKey: Self.paceMarksKey) }
    }

    /// The limits that were burning fast at their last reading, with their window's reset. See `BurningFast`.
    private(set) var burningFastWindows: [String: Date] = [:]

    /// What Priority and the menu bar list as burning fast, or nil while the setting is off.
    var burningFast: BurningFast? {
        showsBurningFast ? BurningFast(latched: burningFastWindows) : nil
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
        self.menuBarLimit = defaults.enumValue(forKey: Self.menuBarLimitKey, default: .upToThree)
        self.menuBarAlwaysShows = defaults.bool(forKey: Self.menuBarAlwaysShowsKey)
        self.priorityLimits = PriorityLimits(
            warning: defaults.object(forKey: Self.priorityWarningKey) as? Int ?? PriorityLimits.standard.warning,
            critical: defaults.object(forKey: Self.priorityCriticalKey) as? Int ?? PriorityLimits.standard.critical
        )
        self.showsBurningFast = defaults.object(forKey: Self.priorityBurningFastKey) as? Bool ?? true
        self.showsUseItOrLoseIt = defaults.object(forKey: Self.priorityUseItOrLoseItKey) as? Bool ?? true
        self.showsPaceMarks = defaults.object(forKey: Self.paceMarksKey) as? Bool ?? false
        let ids = Set(registry.providers.map(\.id))
        self.snapshots = cache.load().filter { ids.contains($0.key) }
        for (id, snapshot) in snapshots { providersByID[id]?.restore(snapshot) }
    }

    func apply(providers: [ProviderRuntime], registry: WidgetRegistry) {
        self.registry = registry
        providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        let ids = Set(providersByID.keys)
        for (id, task) in inFlight where !ids.contains(id) { task.cancel() }
        inFlight = inFlight.filter { ids.contains($0.key) }
        let next = snapshots.filter { ids.contains($0.key) }
        let removed = next.count < snapshots.count
        snapshots = next
        if removed { cache.save(next) }
        backoffs = backoffs.filter { ids.contains($0.key) }
    }

    func refreshAll(force: Bool = false) async {
        await refreshPass(registry.providers.map(\.id), force: force)
    }

    private func refreshPass(_ providerIDs: [String], force: Bool) async {
        let start = ProcessInfo.processInfo.systemUptime
        AppLog.notice(.refresh, "batch start (\(providerIDs.count) providers, force=\(force))")
        let outcomes = await refresh(providerIDs: providerIDs, force: force)
        lastRefreshAt = now()
        let durationMs = durationMilliseconds(since: start)
        let refreshed = outcomes.count { $0 == .refreshed }
        let failed = outcomes.count { $0 == .failed }
        let cached = outcomes.count { $0 == .cacheHit }
        let backedOff = outcomes.count { $0 == .backedOff }
        AppLog.notice(.refresh, "batch end (\(durationMs)ms, \(refreshed) ok / \(failed) failed / \(cached) cached / \(backedOff) backed off)")
    }

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


    enum RefreshOutcome: Sendable { case refreshed, failed, cacheHit, skipped, backedOff }

    @discardableResult
    func refresh(providerID: String, force: Bool = false, rereadHourly: Bool = false) async -> RefreshOutcome {
        if !force, let shown = snapshots[providerID],
           (0..<RefreshSetting.interval).contains(now().timeIntervalSince(shown.refreshedAt)) {
            AppLog.debug(.refresh, "cache hit \(providerID)")
            return .cacheHit
        }
        if !force { AppLog.debug(.refresh, "cache miss \(providerID)") }

        if let backoff = backoffs[providerID], backoff.holds(at: now(), forced: force) {
            AppLog.debug(.refresh, "backoff skip \(providerID) (\(Int(backoff.retryAt.timeIntervalSince(now())))s left)")
            return .backedOff
        }

        if let running = inFlight[providerID] {
            guard force else {
                AppLog.debug(.refresh, "cache skip \(providerID) (already in flight)")
                return .skipped
            }
            if case .failure(let failure) = await running.value, case .rateLimited = failure.kind {
                return .backedOff
            }
            if let next = inFlight[providerID], next != running {
                return await refresh(providerID: providerID, force: force, rereadHourly: rereadHourly)
            }
        }
        guard let provider = providersByID[providerID] else { return .skipped }
        if rereadHourly { provider.forgetHourlyReads() }
        let start = ProcessInfo.processInfo.systemUptime
        let work = Task { [providerRefreshTimeout] in
            await ProviderRefreshDeadline.run(timeout: providerRefreshTimeout) { await provider.refresh() }
                ?? .failure(RefreshFailure(message: "Refresh timed out after \(Int(providerRefreshTimeout))s", kind: .refused))
        }
        inFlight[providerID] = work
        defer { if inFlight[providerID] == work { inFlight[providerID] = nil } }
        let result = await work.value
        guard providersByID[providerID] === provider else {
            AppLog.debug(.refresh, "dropped \(providerID) refresh; the account was removed")
            return .skipped
        }
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
        let snapshot: ProviderSnapshot
        switch result {
        case .failure(let failure): return recordFailure(failure, providerID: providerID)
        case .success(let refreshed): snapshot = refreshed
        }
        store(snapshot, for: providerID)
        AppLog.info(.refresh, "\(providerID) ok (\(durationMs)ms)")
        return .refreshed
    }

    func refreshHourlyReads() async {
        for id in registry.providers.map(\.id) {
            guard let provider = providersByID[id], inFlight[id] == nil, let snapshot = snapshots[id],
                  backoffs[id]?.holds(at: now(), forced: false) != true
            else { continue }
            let read = await ProviderRefreshDeadline.run(timeout: providerRefreshTimeout) {
                await provider.refreshHourlyReads(of: snapshot)
            }
            guard let read else {
                AppLog.warn(.refresh, "\(id) hourly reads timed out after \(Int(providerRefreshTimeout))s")
                continue
            }
            guard let updated = read, providersByID[id] === provider, snapshots[id] == snapshot else { continue }
            snapshots[id] = updated
            cache.save(snapshots)
        }
    }

    private func recordFailure(_ failure: RefreshFailure, providerID: String) -> RefreshOutcome {
        let backoff = RefreshBackoff.after(failure, previous: backoffs[providerID], now: now())
        backoffs[providerID] = backoff
        let wait = Int(backoff.retryAt.timeIntervalSince(now()))
        AppLog.warn(.refresh, "\(providerID) failed: \(failure.message) Next try in \(wait)s.")
        return .failed
    }

    private func durationMilliseconds(since start: TimeInterval) -> Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
    }

    /// Installs a validated key's runtime and snapshot together. Reads started by the previous
    /// runtime can finish later, but the runtime identity check discards their results.
    func replaceProvider(_ provider: ProviderRuntime, snapshot: ProviderSnapshot) {
        let id = provider.provider.id
        inFlight.removeValue(forKey: id)?.cancel()
        providersByID[id] = provider
        store(snapshot, for: id)
    }

    private func store(_ snapshot: ProviderSnapshot, for providerID: String) {
        backoffs[providerID] = nil
        snapshots[providerID] = snapshot
        cache.save(snapshots)
    }

    private func latchBurningFast() {
        let at = now()
        let previous = BurningFast(latched: burningFastWindows)
        var burning: [String: Date] = [:]
        for descriptor in registry.providers.flatMap({ registry.descriptors(for: $0.id) }) {
            let data = data(for: descriptor)
            guard let reset = data.resetsAt,
                  BurningFast.isBurning(data, now: at, wasBurning: previous.wasBurning(descriptor.id, data)) else { continue }
            burning[descriptor.id] = reset
        }
        if burning != burningFastWindows { burningFastWindows = burning }
    }

    func errorMessage(for providerID: String) -> String? {
        backoffs[providerID].flatMap { $0.providerAsked ? nil : $0.message }
    }

    func notice(for providerID: String) -> String? {
        backoffs[providerID] == nil ? snapshots[providerID]?.notice : errorMessage(for: providerID)
    }

    func usageBreakdown(for descriptor: WidgetDescriptor) -> UsageBreakdown? {
        snapshots[descriptor.providerID]?.usageBreakdowns?[descriptor.key]
    }

    func data(for descriptor: WidgetDescriptor) -> WidgetData {
        var result: WidgetData
        if let snapshot = snapshots[descriptor.providerID],
           let line = snapshot.line(label: descriptor.metricLabel)
               ?? descriptor.unreportedValues.map({ .values(label: descriptor.metricLabel, values: $0) }),
           let data = resolve(line, descriptor: descriptor) {
            result = data
            result.title = snapshot.lineTitles?[descriptor.metricLabel] ?? result.title
        } else {
            result = descriptor.sample
            result.hasData = false
        }

        result.displayMode = meterStyle
        result.priorityLimits = priorityLimits
        result.resetDisplayMode = resetDisplayMode
        result.showsPaceMarks = showsPaceMarks
        return result
    }

    /// The accounts with their lines, in the order the dashboard shows them.
    func accounts(in groups: [ProviderMetrics]) -> [DashboardAccount] {
        families(in: groups).flatMap(\.accounts)
    }

    func families(in groups: [ProviderMetrics]) -> [DashboardFamily] {
        DashboardFamily.make(groups: groups, isWaiting: { snapshots[$0.id] == nil && problem(for: $0.id) == nil }) {
            DashboardLine(descriptor: $0, data: data(for: $0))
        }
    }

    func plan(for providerID: String) -> String? {
        snapshots[providerID]?.plan
    }

    /// Why an account needs the user: Priority lists it under Needs Attention, and its page says why and offers Sign In Again.
    /// Old values count only once a refresh has failed. Until then they are waiting for their next read, as on launch.
    func problem(for providerID: String) -> String? {
        notice(for: providerID) ?? (backoffs[providerID] == nil ? nil : stalenessHint(for: providerID))
    }

    func stalenessHint(for providerID: String) -> String? {
        let date = now()
        let backoff = backoffs[providerID]
        if let backoff, backoff.providerAsked, date < backoff.retryAt {
            let name = providersByID[providerID]?.provider.displayName ?? "The provider"
            return "\(name) asked OpenUsage to wait. Retrying at \(Formatters.compactClock(backoff.retryAt, now: date))."
        }
        if let snapshot = snapshots[providerID], snapshot.isStale(at: date),
           let duration = Formatters.compactDuration(date.timeIntervalSince(snapshot.refreshedAt)) {
            return "Last updated \(duration) ago"
        }
        return backoff?.providerAsked == true ? "Waiting to retry after a rate limit." : nil
    }

    private func resolve(_ line: MetricLine, descriptor: WidgetDescriptor) -> WidgetData? {
        switch line {
        case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs):
            let normalizedUsed = format == .percent ? ProviderParse.clampPercent(used) : used
            var result = WidgetData(
                title: descriptor.sample.title,
                kind: format.metricKind,
                currencyCode: format.currencyCode,
                used: normalizedUsed,
                limit: limit,
                resetsAt: resetsAt,
                periodDurationMs: periodDurationMs
            )
            result.sessionStartSignal = descriptor.sample.sessionStartSignal
            return result
        case .values(_, let values, let expiriesAt):
            var data = descriptor.sample
            data.values = values
            data.limit = nil
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

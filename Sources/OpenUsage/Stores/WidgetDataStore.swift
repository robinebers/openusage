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
    private static let slowProviderRefreshThreshold: TimeInterval = 10
    static let defaultProviderRefreshTimeout: TimeInterval = 120

    var snapshots: [String: ProviderSnapshot] = [:]
    private var inFlight: [String: Task<Result<ProviderSnapshot, RefreshFailure>, Never>] = [:]
    var refreshingProviderIDs: Set<String> { Set(inFlight.keys) }
    var lastRefreshAt: Date?

    private(set) var backoffs: [String: RefreshBackoff] = [:]

    var meterStyle: WidgetDisplayMode {
        didSet { defaults.set(meterStyle.rawValue, forKey: Self.meterStyleKey) }
    }

    @ObservationIgnored var onRefreshOutcome: (@MainActor (ProviderKind, RefreshOutcome, Bool) -> Void)?

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
            _ = await running.value
            if let next = inFlight[providerID], next != running {
                return await refresh(providerID: providerID, force: force, rereadHourly: rereadHourly)
            }
        }
        guard let provider = providersByID[providerID] else { return .skipped }
        if rereadHourly { provider.forgetHourlyReads() }
        let start = ProcessInfo.processInfo.systemUptime
        let work = Task { [providerRefreshTimeout] in
            await ProviderRefreshDeadline.refresh(provider, timeout: providerRefreshTimeout)
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
        case .failure(let failure): return recordFailure(failure, providerID: providerID, kind: provider.provider.kind, force: force)
        case .success(let refreshed): snapshot = refreshed
        }
        if backoffs[providerID] != nil { backoffs[providerID] = nil }
        snapshots[providerID] = snapshot
        cache.save(snapshots)
        AppLog.info(.refresh, "\(providerID) ok (\(durationMs)ms)")
        onRefreshOutcome?(provider.provider.kind, .refreshed, force)
        return .refreshed
    }

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

    private func recordFailure(_ failure: RefreshFailure, providerID: String, kind: ProviderKind, force: Bool) -> RefreshOutcome {
        let backoff = RefreshBackoff.after(failure, previous: backoffs[providerID], now: now())
        backoffs[providerID] = backoff
        let wait = Int(backoff.retryAt.timeIntervalSince(now()))
        AppLog.warn(.refresh, "\(providerID) failed: \(failure.message) Next try in \(wait)s.")
        onRefreshOutcome?(kind, .failed, force)
        return .failed
    }

    private func durationMilliseconds(since start: TimeInterval) -> Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
    }

    func errorMessage(for providerID: String) -> String? {
        backoffs[providerID].flatMap { $0.providerAsked ? nil : $0.message }
    }

    func notice(for providerID: String) -> String? {
        backoffs[providerID] == nil ? snapshots[providerID]?.notice : errorMessage(for: providerID)
    }

    func data(for descriptor: WidgetDescriptor) -> WidgetData {
        var result: WidgetData
        if let snapshot = snapshots[descriptor.providerID],
           let line = snapshot.line(label: descriptor.metricLabel),
           let data = resolve(line, descriptor: descriptor) {
            result = data
        } else {
            result = descriptor.sample
            result.hasData = false
        }

        result.displayMode = meterStyle
        result.resetDisplayMode = resetDisplayMode
        return result
    }

    func plan(for providerID: String) -> String? {
        snapshots[providerID]?.plan
    }

    static let stalenessThreshold = RefreshSetting.interval * 2

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

    var hasStaleAccount: Bool {
        guard let lastRefreshAt else { return false }
        return snapshots.contains { id, snapshot in
            backoffs[id] != nil && lastRefreshAt.timeIntervalSince(snapshot.refreshedAt) >= RefreshSetting.interval
        }
    }

    private func resolve(_ line: MetricLine, descriptor: WidgetDescriptor) -> WidgetData? {
        switch line {
        case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs):
            let normalizedUsed = format == .percent ? ProviderParse.clampPercent(used) : used
            var result = WidgetData(
                title: descriptor.sample.title,
                kind: format.metricKind,
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

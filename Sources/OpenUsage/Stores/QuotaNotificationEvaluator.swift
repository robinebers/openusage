import Foundation

/// Owns the quota pace-notification subsystem: the per-metric dedup state, the fire/deliver/commit
/// decision, and the debug trace. Split out of `WidgetDataStore` (which orchestrates refresh + resolves
/// `MetricLine`s) so the notification concern is self-contained. The store gathers each pass's enabled,
/// bounded, visible metrics and calls `evaluate`; delivery + the provider display name come in as
/// closures so this type stays independent of the store's providers.
///
/// Deduped per metric per reset window. No-data metrics never fire; bounded level-only metrics can fire
/// Almost Out, but not pace-based milestones. State for metrics not passed this pass is pruned, so
/// re-enabling/re-adding a metric starts fresh rather than carrying a stale "already fired" flag.
@MainActor
final class QuotaNotificationEvaluator {
    /// One enabled, bounded, visible metric for this pass, already resolved by the store.
    struct Metric {
        let key: String
        let providerID: String
        let data: WidgetData
    }

    private var notificationState: [String: NotificationState] = [:]

    /// Evaluate every metric for a quota pace milestone and deliver a notification for any that just
    /// crossed one, via `post` (id-prefix, title, subtitle, body → delivered?). `providerName` maps a
    /// provider id to its display name for the subtitle.
    func evaluate(
        metrics: [Metric],
        toggles: PaceNotificationToggles,
        now: Date,
        providerName: @MainActor (String) -> String,
        post: @MainActor (String, String, String, String) async -> Bool
    ) async {
        var nextState: [String: NotificationState] = [:]
        for metric in metrics {
            let key = metric.key
            let data = metric.data
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
                let delivered = await deliver(milestone, data: data, providerID: metric.providerID,
                                              providerName: providerName, post: post)
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
    private func deliver(
        _ milestone: PaceMilestone,
        data: WidgetData,
        providerID: String,
        providerName: @MainActor (String) -> String,
        post: @MainActor (String, String, String, String) async -> Bool
    ) async -> Bool {
        let subtitle = "\(providerName(providerID)) \(data.title)"
        return await post("\(providerID).\(milestone.rawValue)", milestone.notificationTitle, subtitle, milestone.body)
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
}

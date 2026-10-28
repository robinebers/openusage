import Foundation

/// Owns the quota pace-notification subsystem: the per-metric dedup state and the fire/deliver/commit
/// decision. `AppContainer`'s loop calls `evaluate` after each pass with the shown metrics in layout
/// order and the data store's values for them.
///
/// Deduped per metric per reset window. No-data metrics never fire; bounded level-only metrics can fire
/// Almost Out, but not pace-based milestones. State for metrics not passed this pass is pruned, so
/// re-enabling/re-adding a metric starts fresh rather than carrying a stale "already fired" flag.
@MainActor
final class QuotaNotificationEvaluator {
    private var notificationState: [String: NotificationState] = [:]
    /// Delivers one notification (id-prefix, title, subtitle, body) and says whether it was delivered.
    private let post: @MainActor (String, String, String, String) async -> Bool

    init(
        post: @escaping @MainActor (String, String, String, String) async -> Bool = { idPrefix, title, subtitle, body in
            await AppNotifications.shared.post(idPrefix: idPrefix, title: title, subtitle: subtitle, body: body)
        }
    ) {
        self.post = post
    }

    /// Evaluate every shown metric for a quota pace milestone and deliver a notification for any that
    /// just crossed one. Unbounded rows and charts have no pace story, so they're skipped. The pass
    /// decides from the values `data` gives before the first delivery `await`, so a refresh landing
    /// mid-pass can't change a later metric's inputs. `providerName` maps a provider id to its display
    /// name for the subtitle.
    func evaluate(
        _ descriptors: [WidgetDescriptor],
        data: (WidgetDescriptor) -> WidgetData,
        isOn: (PaceMilestone) -> Bool,
        now: Date,
        providerName: @MainActor (String) -> String
    ) async {
        let metrics = descriptors.map { ($0, data($0)) }.filter { $0.1.isBounded }
        var nextState: [String: NotificationState] = [:]
        for (descriptor, data) in metrics {
            let key = descriptor.id
            let state = data.meterState(now: now)
            let previous = notificationState[key] ?? NotificationState()
            let result = PaceNotificationLogic.transitions(
                state: state,
                fraction: data.remainingFraction,
                resetsAt: data.resetsAt,
                previous: previous
            )
            // Deliver each fired milestone whose trigger is on, then commit dedup state only for the ones
            // that actually delivered. The logic doesn't mark milestones fired — that's done here, after
            // delivery succeeds, so an undelivered one (trigger off, not authorized, or `add` errored)
            // leaves the milestone un-marked and its edge signal put back, re-firing on the next pass
            // instead of being lost for the rest of the reset window.
            var next = result.newState
            var paceDelivered = false
            var underDelivered = false
            for milestone in result.fire {
                let delivered = isOn(milestone)
                    ? await deliver(milestone, data: data, providerID: descriptor.providerID, providerName: providerName)
                    : false
                if delivered {
                    if milestone == .underTenPercent { underDelivered = true } else { paceDelivered = true }
                    next.firedMilestones.insert(milestone)
                }
            }
            let held = PaceNotificationLogic.carriedOver(previous, resetsAt: data.resetsAt)
            if result.fire.contains(where: { $0 != .underTenPercent }) && !paceDelivered {
                next.previousBucket = held.previousBucket
            }
            if result.fire.contains(.underTenPercent) && !underDelivered {
                next.wasUnderTenPercent = held.wasUnderTenPercent
            }
            if !result.fire.isEmpty {
                AppLog.debug(.notifications, "\(key): \(previous.previousBucket) -> \(next.previousBucket), fired \(result.fire.map(\.rawValue)), delivered pace=\(paceDelivered) under10=\(underDelivered)")
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
        providerName: @MainActor (String) -> String
    ) async -> Bool {
        let subtitle = "\(providerName(providerID)) \(data.title)"
        return await post("\(providerID).\(milestone.rawValue)", milestone.notificationTitle, subtitle, milestone.body)
    }
}

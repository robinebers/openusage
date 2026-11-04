import Foundation

@MainActor
final class QuotaNotificationEvaluator {
    private var notificationState: [String: NotificationState] = [:]
    private let post: @MainActor (String, String, String, String) async -> Bool

    init(
        post: @escaping @MainActor (String, String, String, String) async -> Bool = { idPrefix, title, subtitle, body in
            await AppNotifications.shared.post(idPrefix: idPrefix, title: title, subtitle: subtitle, body: body)
        }
    ) {
        self.post = post
    }

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
                severity: data.severity,
                resetsAt: data.resetsAt,
                unusedNearReset: PaceNotificationLogic.isUnusedNearReset(data, now: now),
                previous: previous
            )
            var next = result.newState
            var paceDelivered = false
            var levelDelivered = false
            for milestone in result.fire {
                // A drop past both levels sends the lowest one that's switched on, not both.
                if levelDelivered, milestone.isLevel {
                    next.firedMilestones.insert(milestone)
                    continue
                }
                let delivered = isOn(milestone)
                    ? await deliver(milestone, data: data, providerID: descriptor.providerID, providerName: providerName)
                    : false
                if delivered {
                    if milestone.isPace { paceDelivered = true }
                    if milestone.isLevel { levelDelivered = true }
                    next.firedMilestones.insert(milestone)
                }
            }
            let held = PaceNotificationLogic.carriedOver(previous, resetsAt: data.resetsAt)
            if result.fire.contains(where: \.isPace) && !paceDelivered {
                next.previousBucket = held.previousBucket
            }
            if result.fire.contains(where: \.isLevel) && !levelDelivered {
                next.previousSeverity = held.previousSeverity
            }
            if !result.fire.isEmpty {
                AppLog.debug(.notifications, "\(key): \(previous.previousBucket) -> \(next.previousBucket), fired \(result.fire.map(\.rawValue)), delivered pace=\(paceDelivered) level=\(levelDelivered)")
            }
            nextState[key] = next
        }
        notificationState = nextState
    }

    private func deliver(
        _ milestone: PaceMilestone,
        data: WidgetData,
        providerID: String,
        providerName: @MainActor (String) -> String
    ) async -> Bool {
        let subtitle = "\(providerName(providerID)) \(data.title)"
        return await post("\(providerID).\(milestone.rawValue)", milestone.notificationTitle, subtitle, milestone.body(data.priorityLimits))
    }
}

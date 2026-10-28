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
                fraction: data.remainingFraction,
                resetsAt: data.resetsAt,
                previous: previous
            )
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

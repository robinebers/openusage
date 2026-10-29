import Foundation

enum PaceMilestone: String, CaseIterable, Hashable, Sendable {
    case underTenPercent
    case healthyToClose
    case closeToRunningOut
}

extension PaceMilestone {
    var settingKey: String { "openusage.notifications.\(rawValue)" }

    var notificationTitle: String {
        switch self {
        case .underTenPercent: return "Almost Out"
        case .healthyToClose: return "Cutting It Close"
        case .closeToRunningOut: return "Will Run Out"
        }
    }

    var settingSubtitle: String {
        switch self {
        case .underTenPercent: return "Alert when a limit drops below 10% remaining."
        case .healthyToClose: return "Alert when a limit is projected to finish with little left."
        case .closeToRunningOut: return "Alert when a limit is projected to finish before it resets."
        }
    }

    var body: String {
        switch self {
        case .underTenPercent: return "Under 10% usage remaining for this window."
        case .healthyToClose: return "Projected to finish close to your limit."
        case .closeToRunningOut: return "Projected to finish before the limit resets."
        }
    }
}

enum PaceBucket: Int, Comparable, Hashable, Sendable {
    case untracked = -1
    case healthy
    case close
    case runningOut

    static func < (lhs: PaceBucket, rhs: PaceBucket) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct NotificationState: Equatable, Sendable {
    var resetsAt: Date?
    var firedMilestones: Set<PaceMilestone> = []
    var previousBucket: PaceBucket = .untracked
    var wasUnderTenPercent: Bool = false
    var primed: Bool = false
}

enum PaceNotificationLogic {
    struct Transition: Equatable {
        var fire: [PaceMilestone]
        var newState: NotificationState
    }

    static func bucket(for state: WidgetData.MeterState) -> PaceBucket {
        switch state {
        case .noData, .level: return .untracked
        case .healthy: return .healthy
        case .closeToLimit: return .close
        case .runningOut, .spent: return .runningOut
        }
    }

    static func transitions(
        state: WidgetData.MeterState,
        fraction: Double,
        resetsAt: Date?,
        previous: NotificationState
    ) -> Transition {
        var next = carriedOver(previous, resetsAt: resetsAt)
        let currentBucket = bucket(for: state)

        if state == .noData {
            return Transition(fire: [], newState: next)
        }

        if !next.primed {
            next.primed = true
            next.previousBucket = currentBucket
            next.wasUnderTenPercent = fraction < 0.10
            next.firedMilestones = []
            return Transition(fire: [], newState: next)
        }

        var fire: [PaceMilestone] = []
        func candidate(_ milestone: PaceMilestone) {
            if !next.firedMilestones.contains(milestone) { fire.append(milestone) }
        }

        if currentBucket != .untracked {
            let previousBucket = next.previousBucket
            if currentBucket == .close, previousBucket < .close { candidate(.healthyToClose) }
            if currentBucket >= .runningOut, previousBucket < .runningOut { candidate(.closeToRunningOut) }
            if currentBucket < previousBucket {
                if currentBucket <= .healthy { next.firedMilestones.remove(.healthyToClose) }
                if currentBucket <= .close { next.firedMilestones.remove(.closeToRunningOut) }
            }
            next.previousBucket = currentBucket
        }

        let underNow = fraction < 0.10
        if underNow, !next.wasUnderTenPercent { candidate(.underTenPercent) }
        if !underNow {
            next.firedMilestones.remove(.underTenPercent)
        }
        next.wasUnderTenPercent = underNow

        return Transition(fire: fire, newState: next)
    }

    static func carriedOver(_ previous: NotificationState, resetsAt: Date?) -> NotificationState {
        var next = previous
        if resetWindowAdvanced(resetsAt: resetsAt, previousReset: previous.resetsAt) {
            next.firedMilestones = []
            next.wasUnderTenPercent = false
            next.previousBucket = .untracked
        }
        next.resetsAt = resetsAt ?? previous.resetsAt
        return next
    }

    static let resetWindowJitterTolerance: TimeInterval = 1

    static func resetWindowAdvanced(resetsAt: Date?, previousReset: Date?) -> Bool {
        guard let resetsAt else { return false }
        guard let previousReset else { return true }
        return resetsAt.timeIntervalSince(previousReset) > resetWindowJitterTolerance
    }
}

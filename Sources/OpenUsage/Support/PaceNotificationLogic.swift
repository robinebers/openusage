import Foundation

enum PaceMilestone: String, CaseIterable, Hashable, Sendable {
    case underTenPercent
    /// Keeps its old raw value, so a saved switch stays on or off through the rename.
    case underThirtyPercent = "healthyToClose"
    case closeToRunningOut
}

extension PaceMilestone {
    var settingKey: String { "openusage.notifications.\(rawValue)" }

    /// The two levels follow what's left, the same rule as Priority. Only this one follows the pace.
    var isPace: Bool { self == .closeToRunningOut }

    var settingSubtitle: String {
        switch self {
        case .underTenPercent: return "A limit drops under 10%"
        case .underThirtyPercent: return "A limit drops under 30%"
        case .closeToRunningOut: return "A limit may run out before its reset"
        }
    }

    var notificationTitle: String {
        switch self {
        case .underTenPercent: return "Almost Out"
        case .underThirtyPercent: return "Cutting It Close"
        case .closeToRunningOut: return "Will Run Out"
        }
    }

    var body: String {
        switch self {
        case .underTenPercent: return "Under 10% left for this window."
        case .underThirtyPercent: return "Under 30% left for this window."
        case .closeToRunningOut: return "May run out before the limit resets."
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
    var previousSeverity: WidgetData.MeterSeverity = .normal
    var primed: Bool = false
}

enum PaceNotificationLogic {
    struct Transition: Equatable {
        var fire: [PaceMilestone]
        var newState: NotificationState
    }

    static func bucket(for state: WidgetData.MeterState) -> PaceBucket {
        switch state {
        case .noData, .unpaced: return .untracked
        case .healthy: return .healthy
        case .closeToLimit: return .close
        case .runningOut, .spent: return .runningOut
        }
    }

    static func transitions(
        state: WidgetData.MeterState,
        severity: WidgetData.MeterSeverity,
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
            next.previousSeverity = severity
            next.firedMilestones = []
            return Transition(fire: [], newState: next)
        }

        var fire: [PaceMilestone] = []
        func candidate(_ milestone: PaceMilestone) {
            if !next.firedMilestones.contains(milestone) { fire.append(milestone) }
        }

        if currentBucket != .untracked {
            let previousBucket = next.previousBucket
            if currentBucket >= .runningOut, previousBucket < .runningOut { candidate(.closeToRunningOut) }
            if currentBucket < previousBucket, currentBucket <= .close {
                next.firedMilestones.remove(.closeToRunningOut)
            }
            next.previousBucket = currentBucket
        }

        if severity == .critical, next.previousSeverity != .critical { candidate(.underTenPercent) }
        if severity != .normal, next.previousSeverity == .normal { candidate(.underThirtyPercent) }
        if severity != .critical { next.firedMilestones.remove(.underTenPercent) }
        if severity == .normal { next.firedMilestones.remove(.underThirtyPercent) }
        next.previousSeverity = severity

        return Transition(fire: fire, newState: next)
    }

    static func carriedOver(_ previous: NotificationState, resetsAt: Date?) -> NotificationState {
        var next = previous
        if resetWindowAdvanced(resetsAt: resetsAt, previousReset: previous.resetsAt) {
            next.firedMilestones = []
            next.previousSeverity = .normal
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

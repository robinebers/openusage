import Foundation

enum PaceMilestone: String, CaseIterable, Hashable, Sendable {
    /// The two levels keep their old raw values, so a saved switch stays on or off through the renames.
    case critical = "underTenPercent"
    case warning = "healthyToClose"
    case closeToRunningOut
}

extension PaceMilestone {
    var settingKey: String { "openusage.notifications.\(rawValue)" }

    /// The two levels follow what's left, the same rule as Priority. Only this one follows the pace.
    var isPace: Bool { self == .closeToRunningOut }

    func settingSubtitle(_ limits: PriorityLimits) -> String {
        switch self {
        case .critical: return "A limit drops to \(limits.critical)% or less left"
        case .warning: return "A limit drops to \(limits.warning)% or less left"
        case .closeToRunningOut: return "A limit may run out before its reset"
        }
    }

    var notificationTitle: String {
        switch self {
        case .critical: return "Critical"
        case .warning: return "Warning"
        case .closeToRunningOut: return "Will Run Out"
        }
    }

    func body(_ limits: PriorityLimits) -> String {
        switch self {
        case .critical: return "\(limits.critical)% or less left for this window."
        case .warning: return "\(limits.warning)% or less left for this window."
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
            // Re-arms only once the pace eases to 90% of the limit, where Priority stops listing it as burning fast.
            if currentBucket == .healthy { next.firedMilestones.remove(.closeToRunningOut) }
            next.previousBucket = currentBucket
        }

        if severity == .critical, next.previousSeverity != .critical { candidate(.critical) }
        if severity != .normal, next.previousSeverity == .normal { candidate(.warning) }
        if severity != .critical { next.firedMilestones.remove(.critical) }
        if severity == .normal { next.firedMilestones.remove(.warning) }
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

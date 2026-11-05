import Foundation

enum PaceMilestone: String, CaseIterable, Hashable, Sendable {
    /// The two levels keep their old raw values, so a saved switch stays on or off through the renames.
    case critical = "underTenPercent"
    case warning = "healthyToClose"
    case closeToRunningOut
    case useItOrLoseIt
}

extension PaceMilestone {
    var settingKey: String { "openusage.notifications.\(rawValue)" }

    /// The two levels follow what's left, the same rule as Priority. Only this one follows the pace.
    var isPace: Bool { self == .closeToRunningOut }

    var isLevel: Bool { self == .critical || self == .warning }

    var settingSubtitle: String {
        switch self {
        case .critical: return "Alert when a limit drops critically low"
        case .warning: return "Alert when a limit requires your attention"
        case .closeToRunningOut: return "A limit may run out before its reset"
        case .useItOrLoseIt: return "Over 50% left a day before its reset"
        }
    }

    var notificationTitle: String {
        switch self {
        case .critical: return "Critical"
        case .warning: return "Warning"
        case .closeToRunningOut: return "Will Run Out"
        case .useItOrLoseIt: return "Use It or Lose It"
        }
    }

    func body(_ limits: PriorityLimits) -> String {
        switch self {
        case .critical: return "\(limits.critical)% or less left for this window."
        case .warning: return "\(limits.warning)% or less left for this window."
        case .closeToRunningOut: return "May run out before the limit resets."
        case .useItOrLoseIt: return "Over 50% left, resets in under 24 hours."
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
        unusedNearReset: Bool,
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
            next.firedMilestones = unusedNearReset ? [.useItOrLoseIt] : []
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

        if unusedNearReset { candidate(.useItOrLoseIt) }

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

    static let useItOrLoseItLead: TimeInterval = 24 * 60 * 60

    /// Only for windows longer than a day, from the provider's own reset and what's left. A session never qualifies,
    /// and neither does a dollar limit: those are spending caps, where nothing is lost at the reset.
    static func isUnusedNearReset(_ data: WidgetData, now: Date) -> Bool {
        guard data.hasData, data.kind != .dollars, let resetsAt = data.resetsAt,
              let periodDurationMs = data.periodDurationMs, periodDurationMs > MetricPeriod.dayMs else { return false }
        let untilReset = resetsAt.timeIntervalSince(now)
        return untilReset > 0 && untilReset <= useItOrLoseItLead && Int((data.remainingFraction * 100).rounded()) > 50
    }

    static let resetWindowJitterTolerance: TimeInterval = 1

    static func resetWindowAdvanced(resetsAt: Date?, previousReset: Date?) -> Bool {
        guard let resetsAt else { return false }
        guard let previousReset else { return true }
        return resetsAt.timeIntervalSince(previousReset) > resetWindowJitterTolerance
    }
}

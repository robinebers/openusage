import Foundation

/// One of the three quota milestones a user can be alerted about. Each maps to a single per-trigger
/// toggle in Settings and is deduped independently within a reset window.
enum PaceMilestone: String, CaseIterable, Hashable, Sendable {
    /// First time the remaining share of the quota drops under 10% for the period.
    case underTenPercent
    /// Pace verdict worsened from healthy (blue) to close-to-limit (orange).
    case healthyToClose
    /// Pace verdict worsened from close-to-limit (orange) to running-out (red).
    case closeToRunningOut
}

extension PaceMilestone {
    /// Notification title, the same as the Settings row so a tapped alert maps back to one row.
    var notificationTitle: String {
        switch self {
        case .underTenPercent: return "Almost Out"
        case .healthyToClose: return "Cutting It Close"
        case .closeToRunningOut: return "Will Run Out"
        }
    }

    /// Notification body — the plain-language verdict. The subtitle carries provider + metric, so the
    /// body stays generic and reads well for any metric (sessions, rate-limit resets, spend tiles).
    var body: String {
        switch self {
        case .underTenPercent: return "Under 10% usage remaining for this window."
        case .healthyToClose: return "Projected to finish close to your limit."
        case .closeToRunningOut: return "Projected to finish before the limit resets."
        }
    }
}

/// The pace-severity bucket a metric is in, derived from its `MeterState`. Only the three live-pace
/// verdicts (and the terminal `spent`) carry a comparable severity; states with no trustworthy pace
/// (`noData`, absolute-band `level`, and a fresh session window) are `untracked` for pace milestones.
/// A `.level` metric may still fire the independent remaining-based Almost Out milestone. Ordered by
/// severity, with `untracked` below `healthy`.
enum PaceBucket: Int, Comparable, Hashable, Sendable {
    /// No pace story to act on (no data, plain level band, or a not-yet-started session window).
    case untracked = -1
    /// On course to finish with ≥10% to spare.
    case healthy
    /// Projected inside the last 10%, cutting it close.
    case close
    /// Projected to run out before the reset, or already spent to nothing.
    case runningOut

    static func < (lhs: PaceBucket, rhs: PaceBucket) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Deduplication state for one metric (provider + descriptor), persisted across refresh passes so a
/// milestone fires once per reset window rather than on every tick. Lives in `WidgetDataStore`.
struct NotificationState: Equatable, Sendable {
    /// The reset instant of the window the fired flags belong to. When this advances (a new window),
    /// the fired set clears so the same milestones can fire again next period.
    var resetsAt: Date?
    /// Milestones already alerted in the current window.
    var firedMilestones: Set<PaceMilestone> = []
    /// The bucket observed on the previous evaluation, so a worsening transition can be detected.
    var previousBucket: PaceBucket = .untracked
    /// Whether the metric was under 10% remaining on the previous evaluation, so the crossing into
    /// under-10% is an edge (and a recovery above 10% re-arms it).
    var wasUnderTenPercent: Bool = false
    /// True once the first real (non-untracked) observation has been recorded as the baseline. Until
    /// then, an already-bad metric at launch is recorded without firing; after, worsening edges fire.
    var primed: Bool = false
}

/// Pure milestone logic — no SwiftUI, no UserNotifications — so the firing rules stay unit-testable.
/// `QuotaNotificationEvaluator.evaluate` feeds it the current `MeterState` + `fraction` + `resetsAt`
/// for each metric and posts a notification for every returned milestone whose trigger is on.
enum PaceNotificationLogic {
    /// Result of one evaluation: the milestones to fire now, and the state to persist for next time.
    struct Transition: Equatable {
        var fire: [PaceMilestone]
        var newState: NotificationState
    }

    /// Maps a meter state to its bucket. The "no trustworthy pace" states (no data, and a level band:
    /// a fresh session, no reset window, too little used) are `untracked` for pace milestones; a level
    /// may still fire the independent remaining-based Almost Out milestone.
    static func bucket(for state: WidgetData.MeterState) -> PaceBucket {
        switch state {
        case .noData, .level: return .untracked
        case .healthy: return .healthy
        case .closeToLimit: return .close
        case .runningOut, .spent: return .runningOut
        }
    }

    /// Decide which milestones to fire for one metric this pass, and the state to persist.
    ///
    /// Rules:
    /// - A new reset window (a meaningfully later `resetsAt`) clears the fired set so milestones can fire
    ///   again. Provider timestamps can jitter by milliseconds between refreshes, so tiny differences are
    ///   treated as the same reset window for notification dedupe.
    /// - `healthyToClose` / `closeToRunningOut` fire only on a worsening *edge* between adjacent
    ///   buckets, and only if not already fired this window.
    /// - `underTenPercent` fires the first time remaining crosses under 10% this window; recovering
    ///   above 10% re-arms it so a later dip re-fires.
    /// - `untracked` states carry no trustworthy pace and therefore suppress pace milestones. No data
    ///   suppresses everything; a level can still fire Almost Out from its remaining share. Neither
    ///   disturbs the recorded pace signals, so a momentary gap does not spuriously re-fire when real
    ///   pace data returns.
    /// - Improving pace clears the relevant fired flags so a later worsening re-fires.
    ///
    /// The state always advances; a milestone that isn't delivered (its trigger off, or the post
    /// failed) doesn't consume its edge, because the evaluator puts the edge's signal back to
    /// `carriedOver(_:resetsAt:)`'s value, so it fires once the trigger is on and the post goes through.
    static func transitions(
        state: WidgetData.MeterState,
        /// Remaining share of the limit, 0...1 — must mean "remaining" regardless of display mode
        /// (callers pass `WidgetData.remainingFraction`, not the display-mode-dependent `fraction`).
        fraction: Double,
        resetsAt: Date?,
        previous: NotificationState
    ) -> Transition {
        var next = carriedOver(previous, resetsAt: resetsAt)
        let currentBucket = bucket(for: state)

        // No real data backing the tile: skip entirely without disturbing recorded signals — a
        // transient no-data tick shouldn't look like an improvement that re-arms milestones, nor a
        // worsening that fires them. (`.level` is different: it has used/limit data even without a pace
        // projection, so "Almost Out" — a remaining-based trigger — still applies to it below.)
        if state == .noData {
            return Transition(fire: [], newState: next)
        }

        // First real observation this launch: record it as the baseline without firing, so a quota
        // already in a bad state when the app opens doesn't spam alerts at launch. From the next
        // evaluation on, worsening edges fire normally. A new reset window mid-session doesn't re-prime
        // — by then the user is watching, so an already-bad metric there can still alert.
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

        // Pace-verdict edges — only for live-pace states (`.level` has no pace projection, so no pace
        // milestones for it). "Cutting It Close" is the orange state itself: it fires only when the
        // metric is *currently* in `.close` having been below it. "Will Run Out" fires when the bucket
        // reaches `.runningOut` having been below it. A jump straight from blue to red fires *Will Run
        // Out only* — the metric skipped orange, so the user gets the single, more urgent alert, never
        // both at once.
        if currentBucket != .untracked {
            let previousBucket = next.previousBucket
            if currentBucket == .close, previousBucket < .close { candidate(.healthyToClose) }
            if currentBucket >= .runningOut, previousBucket < .runningOut { candidate(.closeToRunningOut) }
            // Improving pace clears the now-irrelevant fired flags so a later worsening re-fires them.
            if currentBucket < previousBucket {
                if currentBucket <= .healthy { next.firedMilestones.remove(.healthyToClose) }
                if currentBucket <= .close { next.firedMilestones.remove(.closeToRunningOut) }
            }
            next.previousBucket = currentBucket
        }

        // Under-10%-remaining edge, tracked independently of the pace verdict. Runs for any state with
        // data (pace OR `.level`), since "Almost Out" is about remaining share, not pace projection.
        let underNow = fraction < 0.10
        if underNow, !next.wasUnderTenPercent { candidate(.underTenPercent) }
        if !underNow {
            // Recovered above 10% — re-arm so a later dip fires again.
            next.firedMilestones.remove(.underTenPercent)
        }
        next.wasUnderTenPercent = underNow

        return Transition(fire: fire, newState: next)
    }

    /// `previous` carried into this pass's reset window: a new window (a nil-or-equal reset keeps it; a
    /// reset appearing where there was none, or moving later by more than the jitter tolerance, starts
    /// fresh) clears the fired set and both edge signals.
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

    /// Reset timestamps can carry provider-side millisecond jitter. For notification dedupe, only a
    /// meaningful advance re-arms milestones; the UI can still display the exact provider timestamp.
    static let resetWindowJitterTolerance: TimeInterval = 1

    static func resetWindowAdvanced(resetsAt: Date?, previousReset: Date?) -> Bool {
        guard let resetsAt else { return false }
        guard let previousReset else { return true }
        return resetsAt.timeIntervalSince(previousReset) > resetWindowJitterTolerance
    }
}

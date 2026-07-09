import Foundation

/// One of the three quota milestones a user can be alerted about. Each maps to a single per-trigger
/// toggle in Settings and is deduped independently while its condition remains unchanged.
enum PaceMilestone: String, CaseIterable, Hashable, Sendable {
    /// First time the remaining share of the quota drops under 10%.
    case underTenPercent
    /// Pace verdict worsened from healthy (blue) to close-to-limit (yellow).
    case healthyToClose
    /// Pace verdict worsened from close-to-limit (yellow) to running-out (red).
    case closeToRunningOut
}

extension PaceMilestone {
    /// User-facing label for the Settings row and the notification title (they match by design).
    var settingLabel: String {
        switch self {
        case .underTenPercent: return "Almost Out"
        case .healthyToClose: return "Cutting It Close"
        case .closeToRunningOut: return "Will Run Out"
        }
    }

    /// Notification title. Same as the setting label so a tapped alert maps back to one row.
    var notificationTitle: String { settingLabel }

    /// Notification body — the plain-language verdict. The subtitle carries provider + metric, so the
    /// body stays generic and reads well for any metric (sessions, rate-limit resets, spend tiles).
    var body: String {
        switch self {
        case .underTenPercent: return "Under 10% of this limit remains."
        case .healthyToClose: return "Projected to finish close to your limit."
        case .closeToRunningOut: return "Projected to finish before the limit resets."
        }
    }

    /// One-sentence Settings tooltip (the (i) beside the row) explaining when this fires.
    var tooltip: String {
        switch self {
        case .underTenPercent: return "Alert when a limit drops below 10% remaining."
        case .healthyToClose: return "Alert when a limit is projected to finish with little left."
        case .closeToRunningOut: return "Alert when a limit is projected to finish before it resets."
        }
    }
}

/// The pace-severity bucket a metric is in, derived from its `MeterState`. Only live-pace verdicts carry
/// comparable severity. States without trustworthy pace are `untracked` for pace transitions, while
/// their independent remaining share can still trigger Almost Out when real bounded data exists.
enum PaceBucket: Hashable, Sendable {
    /// No pace story to act on (plain level band, non-paced spent state, or no usable projection).
    case untracked
    /// Blue: on course to finish with ≥10% to spare.
    case healthy
    /// Yellow: projected inside the last 10%, cutting it close.
    case close
    /// Red: projected to run out before the reset, including a spent metric with active pace context.
    case runningOut
}

/// Deduplication state for one metric (provider + descriptor), persisted across refresh passes so a
/// milestone does not fire on every tick. A new reset window clears the reset-based history.
struct NotificationState: Equatable, Sendable {
    /// The reset instant when this metric has a reset window; nil for non-reset balances. When it
    /// advances, the fired set clears so the same milestones can fire again in the new period.
    var resetsAt: Date?
    /// Milestones already alerted while their current condition remains unchanged.
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

/// Which per-milestone toggles are currently on. There is no master switch; turning all three off
/// silences notifications.
struct PaceNotificationToggles: Sendable {
    var underTenPercent: Bool
    var healthyToClose: Bool
    var closeToRunningOut: Bool

    static let allOn = PaceNotificationToggles(underTenPercent: true, healthyToClose: true, closeToRunningOut: true)

    func isOn(_ milestone: PaceMilestone) -> Bool {
        switch milestone {
        case .underTenPercent: return underTenPercent
        case .healthyToClose: return healthyToClose
        case .closeToRunningOut: return closeToRunningOut
        }
    }
}

/// Pure milestone logic — no SwiftUI, no UserNotifications — so the firing rules stay unit-testable.
/// `WidgetDataStore.evaluateNotifications` feeds it the current meter state, remaining fraction, reset,
/// and whether reset-window pace context exists, then posts every returned milestone.
enum PaceNotificationLogic {
    /// Result of one evaluation: the milestones to fire now, and the state to persist for next time.
    struct Transition: Equatable {
        var fire: [PaceMilestone]
        var newState: NotificationState
    }

    /// Maps a meter state to its pace bucket. `.spent` is ambiguous by itself: it represents both an
    /// exhausted reset-based quota and an exhausted balance with no reset. Only the former participates
    /// in pace transitions; both remain eligible for the independent Almost Out threshold.
    static func bucket(
        for state: WidgetData.MeterState,
        hasPaceContext: Bool
    ) -> PaceBucket {
        switch state {
        case .noData, .level: return .untracked
        case .healthy: return .healthy
        case .closeToLimit: return .close
        case .runningOut: return .runningOut
        case .spent: return hasPaceContext ? .runningOut : .untracked
        }
    }

    /// Decide which milestones to fire for one metric this pass, and the state to persist.
    ///
    /// Rules:
    /// - A new reset window (a meaningfully later `resetsAt`) clears the fired set so milestones can fire
    ///   again. Provider timestamps can jitter by milliseconds between refreshes, so tiny differences are
    ///   treated as the same reset window for notification dedupe.
    /// - `healthyToClose` / `closeToRunningOut` fire only on a worsening *edge* between adjacent
    ///   buckets, only if not already fired this window, and only if their toggle is on.
    /// - `underTenPercent` fires when remaining crosses under 10%; recovering above 10% re-arms it so a
    ///   later dip re-fires, including for balances without reset windows.
    /// - `noData` suppresses everything. Other pace-untracked states skip pace edges but can still cross
    ///   the independent under-10% threshold. Untracked states don't disturb the recorded pace signal,
    ///   so a momentary gap doesn't spuriously re-fire when real data returns.
    /// - Improving pace clears the relevant fired flags so a later worsening re-fires.
    static func transitions(
        state: WidgetData.MeterState,
        /// Remaining share of the limit, 0...1 — must mean "remaining" regardless of display mode
        /// (callers pass `WidgetData.remainingFraction`, not the display-mode-dependent `fraction`).
        fraction: Double,
        resetsAt: Date?,
        hasPaceContext: Bool,
        previous: NotificationState,
        toggles: PaceNotificationToggles
    ) -> Transition {
        var next = previous

        // New window: reset dedup. A nil-or-equal reset keeps the window; a reset appearing where there
        // was none or moving later by more than the jitter tolerance starts fresh.
        if resetWindowAdvanced(resetsAt: resetsAt, previousReset: previous.resetsAt) {
            next.firedMilestones = []
            next.wasUnderTenPercent = false
            next.previousBucket = .untracked
        }
        next.resetsAt = resetsAt ?? previous.resetsAt

        let currentBucket = bucket(for: state, hasPaceContext: hasPaceContext)

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

        // Pace-verdict edges — only for live-pace states (`.level` and non-paced `.spent` have no pace
        // projection, so no pace milestones for them). Severity order:
        // untracked(-1) < healthy(0) < close(1) < runningOut(2).
        // "Cutting It Close" is the yellow state itself: it fires only when the metric is *currently*
        // in `.close` having been below it. "Will Run Out" fires when severity reaches `.runningOut`
        // having been below it. A jump straight from blue to red fires *Will Run Out only* — the metric
        // skipped yellow, so the user gets the single, more urgent alert, never both at once.
        if currentBucket != .untracked {
            let previousSeverity = severity(next.previousBucket)
            let currentSeverity = severity(currentBucket)
            var paceFired = false
            if currentBucket == .close, previousSeverity < severity(.close) {
                if maybeFire(.healthyToClose, into: &fire, state: &next, toggles: toggles) { paceFired = true }
            }
            if currentSeverity >= severity(.runningOut), previousSeverity < severity(.runningOut) {
                if maybeFire(.closeToRunningOut, into: &fire, state: &next, toggles: toggles) { paceFired = true }
            }
            // Improving pace clears the now-irrelevant fired flags so a later worsening re-fires them.
            if currentSeverity < previousSeverity {
                if currentSeverity <= severity(.healthy) { next.firedMilestones.remove(.healthyToClose) }
                if currentSeverity <= severity(.close) { next.firedMilestones.remove(.closeToRunningOut) }
            }
            // Advance the recorded bucket only when a worsening was actually alerted (or there was no
            // worsening). A worsening that no enabled trigger caught leaves `previousBucket` where it was,
            // so turning a trigger back on while the quota is still in the worse bucket fires on the next
            // evaluation instead of the crossing being silently consumed.
            if currentSeverity <= previousSeverity || paceFired {
                next.previousBucket = currentBucket
            }
        }

        // Under-10%-remaining edge, tracked independently of the pace verdict. Runs for any state with
        // data (pace OR `.level`), since "Almost Out" is about remaining share, not pace projection.
        // Same consume-guard: a crossing no enabled trigger caught leaves `wasUnderTenPercent` un-advanced,
        // so re-enabling "Almost Out" while still under 10% still alerts.
        let underNow = fraction < 0.10
        let underCrossed = underNow && !next.wasUnderTenPercent
        var underFired = false
        if underCrossed, maybeFire(.underTenPercent, into: &fire, state: &next, toggles: toggles) {
            underFired = true
        }
        if !underNow {
            // Recovered above 10% — re-arm so a later dip fires again.
            next.firedMilestones.remove(.underTenPercent)
        }
        if !underCrossed || underFired {
            next.wasUnderTenPercent = underNow
        }

        return Transition(fire: fire, newState: next)
    }

    /// Returns whether a milestone is a candidate to fire this pass (toggle on, not already fired this
    /// window) and appends it to `fire`. It does NOT mark the milestone fired — the caller commits the
    /// dedup mark only after delivery succeeds, so a skipped/failed delivery doesn't consume the edge.
    @discardableResult
    private static func maybeFire(
        _ milestone: PaceMilestone,
        into fire: inout [PaceMilestone],
        state: inout NotificationState,
        toggles: PaceNotificationToggles
    ) -> Bool {
        guard toggles.isOn(milestone), !state.firedMilestones.contains(milestone) else { return false }
        fire.append(milestone)
        return true
    }

    /// Ordinal pace severity so transitions can be compared (`untracked` sorts below `healthy`).
    private static func severity(_ bucket: PaceBucket) -> Int {
        switch bucket {
        case .untracked: return -1
        case .healthy: return 0
        case .close: return 1
        case .runningOut: return 2
        }
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

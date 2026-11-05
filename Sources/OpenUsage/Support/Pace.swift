import Foundation

enum Pace {
    enum Status {
        case ahead
        case onTrack
        case behind
    }

    struct Result {
        let status: Status
        let projectedUsage: Double
    }

    static func evaluate(used: Double, limit: Double, resetsAt: Date, periodDuration: TimeInterval,
                         now: Date = Date()) -> Result? {
        guard limit > 0, used > 0,
              let share = elapsedShare(resetsAt: resetsAt, periodDuration: periodDuration, now: now) else { return nil }

        let projected = used / share
        if used >= limit { return Result(status: .behind, projectedUsage: projected) }

        let status: Status
        if projected <= limit * 0.9 { status = .ahead }
        else if projected <= limit { status = .onTrack }
        else { status = .behind }
        return Result(status: status, projectedUsage: projected)
    }

    /// How much of the window has passed, or nil until a minute and 1% of it have, and once it resets.
    static func elapsedShare(resetsAt: Date, periodDuration: TimeInterval, now: Date) -> Double? {
        guard periodDuration > 0 else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-periodDuration))
        guard elapsed >= max(60, periodDuration * 0.01), now < resetsAt else { return nil }
        return elapsed / periodDuration
    }
}

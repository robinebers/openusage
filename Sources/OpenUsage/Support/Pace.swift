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

    static func minimumElapsed(periodDuration: TimeInterval) -> TimeInterval {
        max(60, periodDuration * 0.01)
    }

    static func evaluate(used: Double, limit: Double, resetsAt: Date, periodDuration: TimeInterval,
                         now: Date = Date()) -> Result? {
        guard limit > 0, periodDuration > 0, used > 0 else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-periodDuration))
        guard elapsed >= minimumElapsed(periodDuration: periodDuration), now < resetsAt else { return nil }

        let projected = used / elapsed * periodDuration
        if used >= limit { return Result(status: .behind, projectedUsage: projected) }

        let status: Status
        if projected <= limit * 0.9 { status = .ahead }
        else if projected <= limit { status = .onTrack }
        else { status = .behind }
        return Result(status: status, projectedUsage: projected)
    }
}

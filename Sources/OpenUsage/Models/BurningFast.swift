import Foundation

/// Lists a limit that is on pace to run out before it resets, however much it has left. Once a limit is
/// burning fast it stays so until its pace eases to 90% of the limit, so a pace that hovers right at the
/// limit doesn't flicker in and out between readings. The Will Run Out alert re-arms at the same point.
struct BurningFast: Equatable {
    /// The limits that were burning fast at their last reading.
    var latched: Set<String> = []

    func contains(_ line: DashboardLine, now: Date) -> Bool {
        Self.isBurning(line.data, now: now, wasBurning: latched.contains(line.id))
    }

    static func isBurning(_ data: WidgetData, now: Date, wasBurning: Bool) -> Bool {
        switch data.meterState(now: now) {
        case .runningOut: true
        case .closeToLimit: wasBurning
        case .noData, .spent, .healthy, .unpaced: false
        }
    }
}

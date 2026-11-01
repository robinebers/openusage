import Foundation

/// A limit on the board and why it is there.
struct PriorityItem: Identifiable {
    enum Reason: Equatable {
        case runningOut(runway: TimeInterval)
        case closeToLimit(runway: TimeInterval)
        case level(WidgetData.MeterSeverity, usedShare: Double)
        case usedUp(resetsAt: Date?)
        case emptyBalance

        init?(_ line: DashboardLine, now: Date) {
            let data = line.data
            if line.descriptor.balance(in: data)?.number == 0 {
                self = .emptyBalance
                return
            }
            switch data.meterState(now: now) {
            case .runningOut:
                self = .runningOut(runway: data.runway(now: now) ?? .infinity)
            case .closeToLimit:
                self = .closeToLimit(runway: data.runway(now: now) ?? .infinity)
            case .level(.normal), .healthy, .noData:
                return nil
            case .level(let severity):
                self = .level(severity, usedShare: 1 - data.remainingFraction)
            case .spent:
                self = .usedUp(resetsAt: data.resetsAt)
            }
        }

        var severity: WidgetData.MeterSeverity {
            switch self {
            case .runningOut, .usedUp, .emptyBalance: .critical
            case .closeToLimit: .warning
            case .level(let severity, _): severity
            }
        }

        fileprivate var isUsedUp: Bool {
            switch self {
            case .usedUp, .emptyBalance: true
            case .runningOut, .closeToLimit, .level: false
            }
        }

        /// Sorts ascending: first by tier, then by how close the limit is within it.
        fileprivate var rank: (tier: Int, closeness: Double) {
            switch self {
            case .runningOut(let runway): (0, runway)
            case .closeToLimit(let runway): (1, runway)
            case .level(_, let usedShare): (2, -usedShare)
            case .usedUp(let resetsAt): (3, resetsAt?.timeIntervalSinceReferenceDate ?? .infinity)
            case .emptyBalance: (3, .infinity)
            }
        }
    }

    let provider: Provider
    let line: DashboardLine
    let reason: Reason

    var id: String { line.id }
    var data: WidgetData { line.data }

    /// The trailing text of a Used Up row: the time until it resets, or for a balance, which has no reset, its amount.
    func usedUpNote(now: Date) -> String? {
        guard case .emptyBalance = reason else { return data.compactResetText(now: now) }
        return data.unboundedDetail
    }
}

/// The limits that need the user, most urgent first, for the menu bar and the Priority tab.
struct PriorityBoard {
    enum Summary: Equatable {
        case waitingForUsage
        case allClear
        case listed
    }

    let attention: [PriorityItem]
    let usedUp: [PriorityItem]
    let summary: Summary

    /// `accounts` is in the user's saved order, which breaks every tie.
    static func make(accounts: [DashboardAccount], now: Date) -> PriorityBoard {
        let lines = accounts.flatMap { account in account.lines.map { (account.provider, $0) } }
        let items = lines.compactMap { provider, line in
            PriorityItem.Reason(line, now: now).map { PriorityItem(provider: provider, line: line, reason: $0) }
        }
        let ranked = items.enumerated().sorted { lhs, rhs in
            let (left, right) = (lhs.element.reason.rank, rhs.element.reason.rank)
            return (left.tier, left.closeness, lhs.offset) < (right.tier, right.closeness, rhs.offset)
        }.map(\.element)

        let summary: Summary = if !ranked.isEmpty {
            .listed
        } else if lines.contains(where: { $0.1.data.hasData && $0.1.data.isBounded }) {
            .allClear
        } else {
            .waitingForUsage
        }
        return PriorityBoard(
            attention: ranked.filter { !$0.reason.isUsedUp },
            usedUp: ranked.filter(\.reason.isUsedUp),
            summary: summary
        )
    }
}

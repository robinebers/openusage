import Foundation

/// A limit on the board and why it is there.
struct PriorityItem: Identifiable {
    enum Reason: Equatable {
        /// Listed for what's left, the same rule that colors its bar. Time only orders the list.
        case low(WidgetData.MeterSeverity, remaining: Double, runway: TimeInterval?)
        case usedUp(resetsAt: Date?)
        case emptyBalance

        init?(_ line: DashboardLine, now: Date) {
            let data = line.data
            if line.descriptor.balance(in: data)?.number == 0 {
                self = .emptyBalance
                return
            }
            guard data.hasData, data.isBounded else { return nil }
            if data.meterState(now: now) == .spent {
                self = .usedUp(resetsAt: data.resetsAt)
                return
            }
            guard data.severity != .normal else { return nil }
            self = .low(data.severity, remaining: data.remainingFraction, runway: data.runway(now: now))
        }

        var severity: WidgetData.MeterSeverity {
            switch self {
            case .low(let severity, _, _): severity
            case .usedUp, .emptyBalance: .critical
            }
        }

        fileprivate var isUsedUp: Bool {
            switch self {
            case .usedUp, .emptyBalance: true
            case .low: false
            }
        }

        /// Sorts ascending: what runs out soonest first, then what has no pace to tell by, by what's left.
        fileprivate var rank: (tier: Int, closeness: Double) {
            switch self {
            case .low(_, _, let runway?): (0, runway)
            case .low(_, let remaining, nil): (1, remaining)
            case .usedUp(let resetsAt): (2, resetsAt?.timeIntervalSinceReferenceDate ?? .infinity)
            case .emptyBalance: (2, .infinity)
            }
        }
    }

    let provider: Provider
    let line: DashboardLine
    let reason: Reason
    /// The user pinned it. Only an item that is running out is listed while pinned, under Running Out instead of Pinned.
    let isPinned: Bool

    var id: String { line.id }
    var data: WidgetData { line.data }

    /// The trailing text of a Used Up row: the time until it resets, or for a balance, which has no reset, its amount.
    func usedUpNote(now: Date) -> String? {
        guard case .emptyBalance = reason else { return data.compactResetText(now: now) }
        return data.unboundedDetail
    }
}

/// A metric the user pinned to the top of Priority, listed there whatever its reading.
struct PinnedMetric: Identifiable {
    let provider: Provider
    let line: DashboardLine
    /// Its color as Priority would list it, so an empty balance stays red.
    let severity: WidgetData.MeterSeverity

    var id: String { line.id }
    var data: WidgetData { line.data }
}

/// The limits that need the user, most urgent first, for the menu bar and the Priority tab.
struct PriorityBoard {
    enum Summary: Equatable {
        case waitingForUsage
        case noReportedLimits
        case unavailable
        case allClear
        case listed
    }

    enum ReadStatus {
        case waiting, current, unavailable(String)
    }

    struct AccountNotice: Identifiable {
        let provider: Provider
        let message: String
        var id: String { provider.id }
    }

    /// In dashboard order. A pinned metric that is running out is listed only under Running Out, and comes
    /// back here once it isn't. A used-up one stays here and is never listed again under Used Up.
    let pinned: [PinnedMetric]
    let attention: [PriorityItem]
    let usedUp: [PriorityItem]
    let notices: [AccountNotice]
    /// Accounts with no first reading yet, in dashboard order. Each shows as a skeleton row under the rest.
    let waiting: [Provider]
    let summary: Summary
    /// Every account reported and nothing, pinned or not, is running out.
    let showsClearRow: Bool

    /// Multiple running-low limits can change places as their windows age, even without a new reading.
    func requiresRankingClock(at now: Date) -> Bool {
        attention.count > 1 && attention.contains { item in
            guard let reset = item.data.resetsAt, let period = item.data.periodDurationMs else { return false }
            return reset > now && period > 0
        }
    }

    /// `accounts` is in the user's saved order, which breaks every tie.
    static func make(
        accounts: [DashboardAccount], pinned pinnedIDs: Set<String> = [], now: Date,
        status: (DashboardAccount) -> ReadStatus = { $0.lines.contains(where: \.data.hasData) ? .current : .waiting }
    ) -> PriorityBoard {
        let lines = accounts.flatMap { account in account.lines.map { (account.provider, $0) } }
        let items = lines.compactMap { provider, line in
            PriorityItem.Reason(line, now: now).map {
                PriorityItem(provider: provider, line: line, reason: $0, isPinned: pinnedIDs.contains(line.id))
            }
        }
        let ranked = items.enumerated().sorted { lhs, rhs in
            let (left, right) = (lhs.element.reason.rank, rhs.element.reason.rank)
            return (left.tier, left.closeness, lhs.offset) < (right.tier, right.closeness, rhs.offset)
        }.map(\.element)

        var waiting: [Provider] = []
        var notices: [AccountNotice] = []
        for account in accounts {
            switch status(account) {
            case .waiting: waiting.append(account.provider)
            case .unavailable(let message): notices.append(AccountNotice(provider: account.provider, message: message))
            case .current: break
            }
        }
        let awaitingUsage = accounts.isEmpty || !waiting.isEmpty
        let summary: Summary = if !ranked.isEmpty {
            .listed
        } else if !notices.isEmpty {
            .unavailable
        } else if awaitingUsage {
            .waitingForUsage
        } else if lines.contains(where: { $0.1.data.hasData && $0.1.data.isBounded }) {
            .allClear
        } else {
            .noReportedLimits
        }
        let attention = ranked.filter { !$0.reason.isUsedUp }
        let runningOut = Set(attention.map(\.id))
        return PriorityBoard(
            pinned: lines.filter { pinnedIDs.contains($0.1.id) && !runningOut.contains($0.1.id) }.map { provider, line in
                PinnedMetric(provider: provider, line: line, severity: PriorityItem.Reason(line, now: now)?.severity ?? .normal)
            },
            attention: attention,
            usedUp: ranked.filter { $0.reason.isUsedUp && !$0.isPinned },
            notices: notices, waiting: waiting, summary: summary,
            showsClearRow: !awaitingUsage && notices.isEmpty && ranked.allSatisfy(\.reason.isUsedUp)
        )
    }

    /// Whether the tab lists anything, pinned or not, worth copying as a picture.
    var hasRows: Bool { summary == .listed || !pinned.isEmpty }
}

extension WidgetDataStore {
    func priorityBoard(in groups: [ProviderMetrics], pinned: Set<String> = [], now: Date, hidingEmails: Bool = false) -> PriorityBoard {
        let accounts = accounts(in: groups)
        return PriorityBoard.make(accounts: hidingEmails ? accounts.map(\.hidingEmail) : accounts, pinned: pinned, now: now) { account in
            if let message = self.problem(for: account.id) {
                // A provider's notice can itself contain account details. Share only the status.
                return .unavailable(hidingEmails ? "Current usage unavailable." : message)
            }
            return self.snapshots[account.id] == nil ? .waiting : .current
        }
    }
}

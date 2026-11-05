import Foundation

/// A limit on the board and why it is there.
struct PriorityItem: Identifiable {
    enum Reason: Equatable {
        /// Listed for what's left, the same rule that colors its bar.
        case low(WidgetData.MeterSeverity, remaining: Double, runway: TimeInterval?)
        /// Listed with plenty left because it would run out before it resets at the current pace.
        case burningFast(runway: TimeInterval)
        case usedUp(resetsAt: Date?)
        case emptyBalance
        /// Listed with over half left because it resets within a day, the same rule as the Use It or Lose It alert.
        case useItOrLoseIt(resetsAt: Date)

        enum Section { case runningOut, usedUp, useItOrLoseIt }

        /// `burningFast` is nil while Settings leaves limits burning fast off the list, and `useItOrLoseIt` is
        /// false while it leaves limits about to reset unused off.
        init?(_ line: DashboardLine, now: Date, burningFast: BurningFast?, useItOrLoseIt: Bool) {
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
            if data.severity != .normal {
                self = .low(data.severity, remaining: data.remainingFraction, runway: data.runway(now: now))
                return
            }
            if burningFast?.contains(line, now: now) == true, let runway = data.runway(now: now) {
                self = .burningFast(runway: runway)
                return
            }
            guard useItOrLoseIt, PaceNotificationLogic.isUnusedNearReset(data, now: now), let resetsAt = data.resetsAt else { return nil }
            self = .useItOrLoseIt(resetsAt: resetsAt)
        }

        var severity: WidgetData.MeterSeverity {
            switch self {
            case .low(let severity, _, _): severity
            case .burningFast, .useItOrLoseIt: .normal
            case .usedUp, .emptyBalance: .critical
            }
        }

        fileprivate var section: Section {
            switch self {
            case .low, .burningFast: .runningOut
            case .usedUp, .emptyBalance: .usedUp
            case .useItOrLoseIt: .useItOrLoseIt
            }
        }

        /// Sorts ascending: what runs out soonest first, then what has no pace to tell by, by what's left.
        fileprivate var rank: (tier: Int, closeness: Double) {
            switch self {
            case .low(_, _, let runway?), .burningFast(let runway): (0, runway)
            case .low(_, let remaining, nil): (1, remaining)
            case .usedUp(let resetsAt): (2, resetsAt?.timeIntervalSinceReferenceDate ?? .infinity)
            case .emptyBalance: (2, .infinity)
            case .useItOrLoseIt(let resetsAt): (3, resetsAt.timeIntervalSinceReferenceDate)
            }
        }
    }

    let provider: Provider
    let line: DashboardLine
    let reason: Reason
    /// The user pinned it. A pinned item is listed under Running Out, Used Up, or Use It or Lose It instead of Pinned.
    let isPinned: Bool

    var id: String { line.id }
    var data: WidgetData { line.data }

    /// The line under the amount of a limit listed only for burning fast, in place of its reset. A limit still
    /// listed while its pace eases would run out after its reset, so it shows the reset instead.
    func runOutText(now: Date) -> String? {
        guard case .burningFast(let runway) = reason, let resetsAt = data.resetsAt,
              runway < resetsAt.timeIntervalSince(now), let duration = Formatters.compactDuration(runway)
        else { return nil }
        return "Out in \(duration)"
    }

    /// The line under the amount of a limit listed to use before it resets, in place of its reset.
    func resetsInText(now: Date) -> String? {
        guard case .useItOrLoseIt(let resetsAt) = reason, let duration = Formatters.compactDuration(resetsAt.timeIntervalSince(now))
        else { return nil }
        return "Resets in \(duration)"
    }

    /// The trailing text of a Used Up row: the time until it resets, or for a balance, which has no reset, its amount.
    func usedUpNote(now: Date) -> String? {
        guard case .emptyBalance = reason else { return data.compactResetText(now: now) }
        return data.unboundedDetail
    }
}

/// A metric the user pinned to the top of Priority, listed there while no other section lists it.
struct PinnedMetric: Identifiable {
    let provider: Provider
    let line: DashboardLine

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

    /// In dashboard order. A pinned metric another section lists is listed only there, and comes back here
    /// once it isn't.
    let pinned: [PinnedMetric]
    let attention: [PriorityItem]
    let usedUp: [PriorityItem]
    /// Limits with over half left that reset within a day, soonest reset first. Never in the menu bar.
    let useItOrLoseIt: [PriorityItem]
    let notices: [AccountNotice]
    /// Accounts with no first reading yet, in dashboard order. Each shows as a skeleton row under the rest.
    let waiting: [Provider]
    let summary: Summary
    /// Every account reported and nothing, pinned or not, is running out.
    let showsClearRow: Bool

    /// Multiple running-low limits can change places as their windows age, even without a new reading, and a
    /// limit burning fast can slow off the list.
    func requiresRankingClock(at now: Date) -> Bool {
        if attention.contains(where: { if case .burningFast = $0.reason { true } else { false } }) { return true }
        return attention.count > 1 && attention.contains { item in
            guard let reset = item.data.resetsAt, let period = item.data.periodDurationMs else { return false }
            return reset > now && period > 0
        }
    }

    /// `accounts` is in the user's saved order, which breaks every tie. `burningFast` is nil while Settings
    /// leaves limits burning fast off the list, and `useItOrLoseIt` is false while it leaves that section off.
    static func make(
        accounts: [DashboardAccount], pinned pinnedIDs: Set<String> = [], burningFast: BurningFast? = nil,
        useItOrLoseIt: Bool = false, now: Date,
        status: (DashboardAccount) -> ReadStatus = { $0.lines.contains(where: \.data.hasData) ? .current : .waiting }
    ) -> PriorityBoard {
        let lines = accounts.flatMap { account in account.lines.map { (account.provider, $0) } }
        let items = lines.compactMap { provider, line in
            PriorityItem.Reason(line, now: now, burningFast: burningFast, useItOrLoseIt: useItOrLoseIt).map {
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
        let listed = Set(ranked.map(\.id))
        return PriorityBoard(
            pinned: lines.filter { pinnedIDs.contains($0.1.id) && !listed.contains($0.1.id) }.map(PinnedMetric.init),
            attention: ranked.filter { $0.reason.section == .runningOut },
            usedUp: ranked.filter { $0.reason.section == .usedUp },
            useItOrLoseIt: ranked.filter { $0.reason.section == .useItOrLoseIt },
            notices: notices, waiting: waiting, summary: summary,
            showsClearRow: !awaitingUsage && notices.isEmpty && !ranked.contains { $0.reason.section == .runningOut }
        )
    }

    /// Whether the tab lists anything, pinned or not, worth copying as a picture.
    var hasRows: Bool { summary == .listed || !pinned.isEmpty }
}

extension WidgetDataStore {
    func priorityBoard(in groups: [ProviderMetrics], pinned: Set<String> = [], now: Date, hidingEmails: Bool = false) -> PriorityBoard {
        let accounts = accounts(in: groups)
        return PriorityBoard.make(
            accounts: hidingEmails ? accounts.map(\.hidingEmail) : accounts, pinned: pinned, burningFast: burningFast,
            useItOrLoseIt: showsUseItOrLoseIt, now: now
        ) { account in
            if let message = self.problem(for: account.id) {
                // A provider's notice can itself contain account details. Share only the status.
                return .unavailable(hidingEmails ? "Current usage unavailable." : message)
            }
            return self.snapshots[account.id] == nil ? .waiting : .current
        }
    }
}

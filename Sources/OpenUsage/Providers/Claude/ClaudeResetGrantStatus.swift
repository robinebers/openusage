import Foundation

struct ClaudeResetGrantStatus: Hashable, Sendable, Codable {
    struct Grant: Hashable, Sendable, Codable {
        var id: String
        var resetsLeft: Int
        var endsAt: Date?
        var clears: [String]
        var type: String?
        var givesBackWeekly = false
        var usableNow = false
        var paused = false

        /// What the grant refills, decided as Claude Code decides it: a grant that gives back the week's
        /// Fable use is a Fable reset whatever its type says, then the type, then the windows it clears.
        var kind: ResetKind {
            if givesBackWeekly { return .fable }
            switch type {
            case "session": return .session
            case "weekly": return .weekly
            case "full": return .full
            default: break
            }
            let session = clears.contains("five_hour")
            let other = clears.contains { $0 != "five_hour" }
            if session && !other { return .session }
            if other && !session { return .weekly }
            return .full
        }

        var confirmDetail: String? {
            // A window this doesn't recognize leaves the general wording, never a list that understates.
            var names: [String] = []
            for window in clears {
                switch window {
                case "five_hour": names.append("session")
                case "seven_day": names.append("weekly")
                case "seven_day_overage_included": names.append("Fable")
                default: return nil
                }
            }
            guard let last = names.last else { return nil }
            var detail = names.count == 1
                ? "Refills your \(last) limit now"
                : "Refills your \(names.dropLast().joined(separator: ", ")) and \(last) limits now"
            if givesBackWeekly, !clears.contains("seven_day") {
                detail += " and gives back what Fable used of your weekly limit"
            }
            return detail + ". This can't be undone."
        }
    }

    var eligible: Bool
    var grants: [Grant]
    var nextGrantID: String?

    static func parse(_ value: Any?) -> ClaudeResetGrantStatus? {
        guard let object = value as? [String: Any] else { return nil }
        var grants: [Grant] = []
        for entry in object["grants"] as? [Any] ?? [] {
            guard let grant = entry as? [String: Any],
                  let id = grant["id"] as? String, !id.isEmpty,
                  let left = ProviderParse.number(grant["resets_left"]).flatMap({ ProviderParse.int($0.rounded(.down)) })
            else {
                AppLog.warn(LogTag.plugin("claude"), "reset grants block has a malformed grant; ignoring the block")
                return nil
            }
            grants.append(Grant(
                id: id,
                resetsLeft: max(0, left),
                endsAt: ClaudeUsageMapper.resetDate(grant["ends_at"]),
                clears: grant["clears"] as? [String] ?? [],
                type: grant["type"] as? String,
                givesBackWeekly: grant["gives_back_weekly"] as? Bool == true,
                usableNow: grant["usable_now"] as? Bool == true,
                paused: grant["paused"] as? Bool == true
            ))
        }
        let nextGrantID = (object["next_grant_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeResetGrantStatus(
            eligible: object["eligible"] as? Bool == true,
            grants: grants,
            nextGrantID: nextGrantID
        )
    }

    /// The grant a claim names, while the last check still lists a reset left on it.
    func claimableGrant(_ grantID: String) -> Grant? {
        guard eligible else { return nil }
        return grants.first { $0.id == grantID && $0.resetsLeft > 0 }
    }

    /// One row per reset left, each claiming its own grant. Use shows only where Anthropic says the grant
    /// can be used now.
    func items(now: Date) -> [ResetItem] {
        availableGrants(now: now).flatMap { grant -> [ResetItem] in
            guard let endsAt = grant.endsAt else { return [] }
            let item = ResetItem(
                kind: grant.kind, expiresAt: endsAt, claim: .claudeGrant(grant.id),
                usable: grant.usableNow && !grant.paused, confirmDetail: grant.confirmDetail
            )
            return Array(repeating: item, count: grant.resetsLeft)
        }
    }

    /// The grants whose resets the row counts: eligible, with a reset left, and not yet expired.
    func availableGrants(now: Date) -> [Grant] {
        guard eligible else { return [] }
        return grants.filter { grant in
            grant.resetsLeft >= 1 && !(grant.endsAt.map { $0 <= now } ?? false)
        }
    }

    static let lineLabel = "Rate Limit Resets"

    func line(now: Date) -> MetricLine {
        var count = 0
        var expiries: [Date] = []
        for grant in availableGrants(now: now) {
            count += grant.resetsLeft
            if let endsAt = grant.endsAt { expiries += Array(repeating: endsAt, count: grant.resetsLeft) }
        }
        return .values(
            label: Self.lineLabel,
            values: [MetricValue(number: Double(count), kind: .count, label: "available")],
            expiriesAt: expiries.sorted()
        )
    }
}

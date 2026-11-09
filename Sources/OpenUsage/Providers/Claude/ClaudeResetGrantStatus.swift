import Foundation

struct ClaudeResetGrantStatus: Equatable, Sendable {
    struct Grant: Equatable, Sendable {
        var id: String
        var resetsLeft: Int
        var endsAt: Date?
        var clears: [String]
        var label: String?
        var givesBackWeekly = false

        /// The model whose weekly limit `seven_day_overage_included` is. The key names no model, so it
        /// is read from the grant's own id and label.
        var scopedModel: String? {
            guard clears.contains("seven_day_overage_included"),
                  "\(id) \(label ?? "")".localizedCaseInsensitiveContains("fable")
            else { return nil }
            return "Fable"
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
                label: grant["label"] as? String,
                givesBackWeekly: grant["gives_back_weekly"] as? Bool == true
            ))
        }
        let nextGrantID = (object["next_grant_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeResetGrantStatus(
            eligible: object["eligible"] as? Bool == true,
            grants: grants,
            nextGrantID: nextGrantID
        )
    }

    var claimableGrantID: String? {
        guard eligible, let nextGrantID, grants.contains(where: { $0.id == nextGrantID && $0.resetsLeft > 0 }) else {
            return nil
        }
        return nextGrantID
    }

    var confirmDetail: String? {
        guard let id = claimableGrantID, let grant = grants.first(where: { $0.id == id }) else { return nil }
        // A window this doesn't recognize leaves the general wording, never a list that understates.
        var names: [String] = []
        for window in grant.clears {
            switch window {
            case "five_hour": names.append("session")
            case "seven_day": names.append("weekly")
            case "seven_day_overage_included":
                guard let model = grant.scopedModel else { return nil }
                names.append(model)
            default: return nil
            }
        }
        guard !names.isEmpty else { return nil }
        var detail = "Refills your \(names.joined(separator: " and ")) limits now"
        if grant.givesBackWeekly, let model = grant.scopedModel, !grant.clears.contains("seven_day") {
            detail += ", and takes this week's \(model) use off your weekly limit"
        }
        return detail + ". This can't be undone."
    }

    /// The resets by what they refill, each kind under its own title: one model's resets apart from
    /// the ordinary ones. An account with one kind still gets that kind's title.
    func sections(now: Date) -> [ResetSection] {
        let open = availableGrants(now: now)
        var models: [String?] = []
        for grant in open where !models.contains(grant.scopedModel) { models.append(grant.scopedModel) }
        let next = claimableGrantID
        return models.map { model in
            let grants = open.filter { $0.scopedModel == model }
            return ResetSection(
                title: model.map { "\($0) Resets" } ?? Self.ordinaryTitle(grants),
                expiries: grants.flatMap { grant in
                    grant.endsAt.map { Array(repeating: $0, count: grant.resetsLeft) } ?? []
                }.sorted(),
                usable: grants.contains { $0.id == next }
            )
        }
    }

    private static func ordinaryTitle(_ grants: [Grant]) -> String {
        let cleared = Set(grants.flatMap(\.clears))
        let names = [("five_hour", "Session"), ("seven_day", "Weekly")].filter { cleared.contains($0.0) }.map(\.1)
        return names.isEmpty ? "Other Resets" : names.joined(separator: " & ") + " Resets"
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

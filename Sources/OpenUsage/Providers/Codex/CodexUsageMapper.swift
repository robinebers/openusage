import Foundation

enum CodexUsageMapper {
    /// OpenAI sells ChatGPT credits at 4¢ each; the usage API reports only the count.
    private static let creditUSDRate = 0.04

    static func mapUsageResponse(
        _ response: HTTPResponse,
        resetCredits: HTTPResponse? = nil,
        now: Date = Date()
    ) throws -> ProviderUsage {
        try ProviderError.requireSuccess(response, kind: .codex)

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw ProviderError.invalidResponse
        }

        var lines: [MetricLine] = []
        let rateLimit = body["rate_limit"] as? [String: Any]
        lines.append(contentsOf: windowLines(
            rateLimit: rateLimit,
            labels: (session: "Session", weekly: "Weekly"),
            headerPercents: (
                primary: ProviderParse.number(response.header("x-codex-primary-used-percent")),
                secondary: ProviderParse.number(response.header("x-codex-secondary-used-percent"))
            ),
            now: now
        ))

        lines.append(contentsOf: sparkLines(body: body, now: now))

        if let resets = readResetCredits(body: body, resetCredits: resetCredits) {
            lines.append(.values(
                label: "Rate Limit Resets",
                values: [MetricValue(number: Double(resets.count), kind: .count, label: "available")],
                expiriesAt: resets.expiries
            ))
        }

        if let remaining = readCreditsRemaining(response: response, body: body) {
            lines.append(.values(label: "Credits", values: creditValues(remaining: remaining)))
        }

        return ProviderUsage(plan: formatCodexPlan(body["plan_type"]), lines: lines)
    }

    /// Codex normally returns the five-hour window as `primary_window` and the weekly window as
    /// `secondary_window`, but it can move a temporarily sole weekly limit into the primary slot. Each
    /// meter takes the window whose explicit duration is its own; failing that, the window in its own slot
    /// when that window's duration is absent or unfamiliar. A slot known only from its header percent is a
    /// window with no fields. The meter keeps the percentage Codex reported and the window's own period,
    /// falling back to the meter's; a chosen window without a percentage shows nothing.
    private static func windowLines(
        rateLimit: [String: Any]?,
        labels: (session: String, weekly: String),
        headerPercents: (primary: Double?, secondary: Double?) = (nil, nil),
        now: Date
    ) -> [MetricLine] {
        let slots = [
            (rateLimit?["primary_window"], headerPercents.primary),
            (rateLimit?["secondary_window"], headerPercents.secondary)
        ].map { value, headerPercent -> (window: [String: Any], usedPercent: Double?)? in
            guard let window = value as? [String: Any] ?? (headerPercent == nil ? nil : [:]) else { return nil }
            return (window, ProviderParse.number(window["used_percent"]) ?? headerPercent)
        }
        let meters = [(label: labels.session, periodMs: MetricPeriod.sessionMs), (label: labels.weekly, periodMs: MetricPeriod.weekMs)]
        let familiarPeriods = meters.map(\.periodMs)
        return meters.enumerated().compactMap { slot, meter in
            let exact = slots.compactMap { $0 }.first { readPeriodMs($0.window) == meter.periodMs }
            let fallback = slots[slot].flatMap { candidate in
                readPeriodMs(candidate.window).map(familiarPeriods.contains) == true ? nil : candidate
            }
            guard let candidate = exact ?? fallback, let used = candidate.usedPercent else { return nil }
            let periodMs = readPeriodMs(candidate.window) ?? meter.periodMs
            return .percent(meter.label, used, resetsAt: resetDate(candidate.window, now: now), periodMs: periodMs)
        }
    }

    private static func sparkLines(body: [String: Any], now: Date) -> [MetricLine] {
        guard let rawEntries = body["additional_rate_limits"] as? [Any] else { return [] }
        let entries = rawEntries.compactMap { $0 as? [String: Any] }
        guard let spark = entries.first(where: isSparkEntry),
              let rateLimit = spark["rate_limit"] as? [String: Any]
        else {
            return []
        }

        return windowLines(
            rateLimit: rateLimit,
            labels: (session: "Spark", weekly: "Spark Weekly"),
            now: now
        )
    }

    private static func isSparkEntry(_ entry: [String: Any]) -> Bool {
        [entry["limit_name"], entry["metered_feature"]]
            .compactMap { ($0 as? String)?.lowercased() }
            .contains { $0.contains("spark") }
    }

    private static func resetDate(_ window: [String: Any]?, now: Date) -> Date? {
        guard let window else { return nil }
        if let resetAt = ProviderParse.number(window["reset_at"]) {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetAfter = ProviderParse.number(window["reset_after_seconds"]) {
            return now.addingTimeInterval(resetAfter)
        }
        return nil
    }

    private static func readPeriodMs(_ window: [String: Any]?) -> Int? {
        guard let window else { return nil }
        guard let seconds = ProviderParse.number(window["limit_window_seconds"]) else { return nil }
        return Int(seconds * 1000)
    }

    static func creditValues(remaining: Double) -> [MetricValue] {
        let credits = max(0, Int(remaining.rounded(.down)))
        return [
            MetricValue(number: Double(credits) * creditUSDRate, kind: .dollars),
            MetricValue(number: Double(credits), kind: .count, label: "credits")
        ]
    }

    /// The count comes from the usage body of this pass; the dedicated list, read hourly, supplies the
    /// count only when the usage body has none, and its expiry times only while it agrees with the count,
    /// so an hour-old list never stands in for a reset spent or granted since.
    static func readResetCredits(
        body: [String: Any],
        resetCredits: HTTPResponse?
    ) -> (count: Int, expiries: [Date])? {
        let embedded = body["rate_limit_reset_credits"] as? [String: Any]
        let dedicated = resetCredits.flatMap { response -> [String: Any]? in
            guard (200..<300).contains(response.statusCode), let body = ProviderParse.jsonObject(response.body),
                  availableCount(in: body) != nil
            else { return nil }
            return body
        }
        guard let count = embedded.flatMap(availableCount) ?? dedicated.flatMap(availableCount) else { return nil }
        guard count > 0 else { return (0, []) }
        if let dedicated, availableCount(in: dedicated) == count {
            return (count, availableResetCredits(in: dedicated).compactMap(\.expiry).sorted())
        }
        return (count, embedded.map { availableResetCredits(in: $0).compactMap(\.expiry).sorted() } ?? [])
    }

    /// `ProviderParse.number` because a JSON `null` decodes to `NSNull`, which a bare nil-check would accept.
    private static func availableCount(in source: [String: Any]) -> Int? {
        guard let count = ProviderParse.number(source["available_count"]), count >= 0 else { return nil }
        return Int(count.rounded(.down))
    }

    static func resetCreditID(in body: [String: Any], expiringAt expiry: Date) -> String? {
        availableResetCredits(in: body).first { credit in
            credit.expiry.map { abs($0.timeIntervalSince(expiry)) < 1 } ?? false
        }?.id
    }

    private static func availableResetCredits(in source: [String: Any]) -> [(id: String?, expiry: Date?)] {
        guard let credits = source["credits"] as? [[String: Any]] else { return [] }
        return credits
            .filter { credit in
                guard let status = credit["status"] as? String else { return true }
                return status == "available"
            }
            .map { credit in (credit["id"] as? String, parseExpiry(credit["expires_at"])) }
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
        if let string = value as? String, let date = OpenUsageISO8601.date(from: string) {
            return date
        }
        if let seconds = ProviderParse.number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// Collapses a consume response to the popover's outcome. Every protocol code arrives as HTTP 200 with
    /// the outcome in the body's `code`; `already_redeemed` is the idempotency key absorbing a retry of a
    /// claim that already landed, so it counts as success.
    static func resetClaimOutcome(from response: HTTPResponse) -> ResetClaimOutcome {
        if ProviderError.isAuthFailure(response) { return .failed(.signInExpired) }
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let code = body["code"] as? String
        else {
            return .failed(.refused)
        }
        switch code {
        case "reset", "already_redeemed": return .success
        case "nothing_to_reset": return .nothingToReset
        case "no_credit": return .noCredit
        default: return .failed(.refused)
        }
    }

    private static func readCreditsRemaining(response: HTTPResponse, body: [String: Any]) -> Double? {
        if let credits = body["credits"] as? [String: Any] {
            if let balance = ProviderParse.number(credits["balance"]) {
                return balance
            }
            if credits["has_credits"] as? Bool == false {
                return 0
            }
        }
        return ProviderParse.number(response.header("x-codex-credits-balance"))
    }

    static func formatCodexPlan(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        switch raw.lowercased() {
        case "prolite":
            return "Pro 100"
        case "pro":
            return "Pro 200"
        case "promax":
            return "Pro 500"
        case "self_serve_business_prolite":
            return "Business Premium"
        default:
            return raw.titleCased(separator: { $0 == "_" })
        }
    }

}

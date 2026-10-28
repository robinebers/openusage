import Foundation

/// Builds metric lines from the ollama.com `/api/balance` payload and the plan name from `/api/me`.
///
/// Current plans carry a monthly dollar allowance:
///
///     {"included": {"balance_usd": 72.5, "allowance_usd": 100,
///                   "period": {"from": "2026-09-15T09:30:00Z", "until": "2026-10-15T09:30:00Z"}},
///      "purchased": {"balance_usd": 25}}
///
/// Legacy plans keep their session and weekly limits instead, as a percentage *remaining*:
///
///     {"included": {"session": {"remaining_percent": 75, "resets_at": "2026-10-01T07:00:00Z"},
///                   "weekly":  {"remaining_percent": 40, "resets_at": "2026-10-05T00:00:00Z"}},
///      "purchased": {"balance_usd": 25}}
///
/// See https://docs.ollama.com/api/balance. The mapper is pure — no I/O — so it tests directly against
/// sample payloads.
enum OllamaUsageMapper {
    /// The plan and lines from the balance payload plus the optional account payload. `accountBody` may be
    /// `nil` — the plan request is best-effort and must never blank out the meters.
    static func map(balanceBody: Data, accountBody: Data?) throws -> ProviderUsage {
        ProviderUsage(plan: accountBody.flatMap(plan(from:)), lines: try balanceLines(balanceBody))
    }

    /// Session and Weekly (legacy plans) or Monthly (current plans), then Purchased Credits.
    static func balanceLines(_ body: Data) throws -> [MetricLine] {
        // `included` is the plan allowance this provider exists to show. Missing, or matching neither
        // documented shape, means the response isn't one OpenUsage understands: a loud failure rather
        // than an empty dashboard.
        guard let root = ProviderParse.jsonObject(body),
              let included = root["included"] as? [String: Any] else {
            throw ProviderError.invalidResponse
        }

        var lines: [MetricLine] = []
        if let session = legacyLine(included["session"], label: "Session", periodMs: MetricPeriod.sessionMs) {
            lines.append(session)
        }
        if let weekly = legacyLine(included["weekly"], label: "Weekly", periodMs: MetricPeriod.weekMs) {
            lines.append(weekly)
        }
        if let monthly = monthlyLine(included) {
            lines.append(monthly)
        }
        guard !lines.isEmpty else { throw ProviderError.invalidResponse }

        if let purchased = purchasedLine(root["purchased"]) {
            lines.append(purchased)
        }
        return lines
    }

    /// The account's plan, title-cased for the header badge ("pro" → "Pro"), or `nil` when the body is
    /// not an account or names no plan. Called directly, ollama.com capitalizes its JSON keys (`Plan`);
    /// the local Ollama server lowercases them when it proxies the same response, so both spellings
    /// are accepted.
    static func plan(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let text = (root["Plan"] ?? root["plan"]) as? String,
              let name = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else { return nil }
        return name.capitalized
    }

    // MARK: - Private

    /// A legacy limit → a 0–100% used meter. Ollama reports what *remains*, so used = 100 − remaining.
    private static func legacyLine(_ entry: Any?, label: String, periodMs: Int) -> MetricLine? {
        guard let entry = entry as? [String: Any],
              let remaining = ProviderParse.number(entry["remaining_percent"]) else { return nil }
        // The period only pairs with a real reset; alone it would render a static "Resets in 5h".
        let resetsAt = date(entry["resets_at"])
        let used = ProviderParse.clampPercent(100 - remaining)
        return .percent(label, used, resetsAt: resetsAt, periodMs: resetsAt == nil ? nil : periodMs)
    }

    /// The monthly allowance → a dollar meter: used = allowance − balance, resetting at `period.until`.
    private static func monthlyLine(_ included: [String: Any]) -> MetricLine? {
        guard let allowance = ProviderParse.number(included["allowance_usd"]), allowance > 0,
              let balance = ProviderParse.number(included["balance_usd"]) else { return nil }
        let period = included["period"] as? [String: Any]
        let from = date(period?["from"])
        let until = date(period?["until"])
        var periodMs: Int?
        if let from, let until, until > from {
            periodMs = Int(until.timeIntervalSince(from) * 1000)
        }
        return .progress(
            label: "Monthly",
            used: min(allowance, max(0, allowance - balance)),
            limit: allowance,
            format: .dollars,
            resetsAt: until,
            periodDurationMs: periodMs
        )
    }

    /// Unexpired purchased credits → an unbounded dollar row. A real zero is shown, not "No data".
    private static func purchasedLine(_ purchased: Any?) -> MetricLine? {
        guard let purchased = purchased as? [String: Any],
              let balance = ProviderParse.number(purchased["balance_usd"]) else { return nil }
        return .values(
            label: "Purchased Credits",
            values: [MetricValue(number: max(0, balance), kind: .dollars)]
        )
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap(OpenUsageISO8601.date(from:))
    }
}

import Foundation

/// What an account response said about the plan. Distinct from a plain `String?` because "no badge" has
/// two very different causes: an account that has no plan (ordinary) and a response OpenUsage could not
/// read (worth a warning, since the badge otherwise just disappears).
enum OllamaPlan: Equatable, Sendable {
    /// A usable plan name for the header badge.
    case named(String)
    /// The response was readable and carries no plan.
    case absent
    /// The response could not be read as an account: not a JSON object, or no usable plan field.
    case unreadable

    /// The name to show, or `nil` when there is nothing to show.
    var name: String? {
        if case .named(let name) = self { return name }
        return nil
    }
}

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
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    /// `(plan, lines)` from the balance payload plus the optional account payload. `accountBody` may be
    /// `nil` — the plan request is best-effort and must never blank out the meters.
    static func map(balanceBody: Data, accountBody: Data?) throws -> (plan: OllamaPlan, lines: [MetricLine]) {
        // A `nil` body means the account request itself failed, which the provider has already reported;
        // classifying it as unreadable here would warn about the same thing twice.
        let outcome = accountBody.map { plan(from: $0) } ?? .absent
        return (outcome, try balanceLines(balanceBody))
    }

    /// Session and Weekly (legacy plans) or Monthly (current plans), then Purchased Credits.
    static func balanceLines(_ body: Data) throws -> [MetricLine] {
        // `included` is the plan allowance this provider exists to show. Missing, or matching neither
        // documented shape, means the response isn't one OpenUsage understands: a loud failure rather
        // than an empty dashboard.
        guard let root = ProviderParse.jsonObject(body),
              let included = root["included"] as? [String: Any] else {
            throw OllamaUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        if let session = legacyLine(included["session"], label: "Session", periodMs: sessionPeriodMs) {
            lines.append(session)
        }
        if let weekly = legacyLine(included["weekly"], label: "Weekly", periodMs: weeklyPeriodMs) {
            lines.append(weekly)
        }
        if let monthly = monthlyLine(included) {
            lines.append(monthly)
        }
        guard !lines.isEmpty else { throw OllamaUsageError.invalidResponse }

        if let purchased = purchasedLine(root["purchased"]) {
            lines.append(purchased)
        }
        return lines
    }

    /// The account's plan, title-cased for the header badge ("pro" → "Pro"). Called directly, ollama.com
    /// capitalizes its JSON keys (`Plan`); the local Ollama server lowercases them when it proxies the
    /// same response, so both spellings are accepted.
    ///
    /// The three outcomes are kept apart on purpose. A body that isn't an account, or one whose plan
    /// field has vanished or changed type, means OpenUsage can no longer read something it expects —
    /// worth telling the user about. A plan field that is explicitly empty is just an account with no
    /// plan, which is ordinary and must stay quiet.
    static func plan(from body: Data) -> OllamaPlan {
        guard let root = ProviderParse.jsonObject(body) else { return .unreadable }
        guard let raw = root["Plan"] ?? root["plan"] else { return .unreadable }
        guard let text = raw as? String else { return .unreadable }
        guard let name = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return .absent
        }
        return .named(name.capitalized)
    }

    // MARK: - Private

    /// A legacy limit → a 0–100% used meter. Ollama reports what *remains*, so used = 100 − remaining.
    private static func legacyLine(_ entry: Any?, label: String, periodMs: Int) -> MetricLine? {
        guard let entry = entry as? [String: Any],
              let remaining = ProviderParse.number(entry["remaining_percent"]) else { return nil }
        // The period only pairs with a real reset; alone it would render a static "Resets in 5h".
        let resetsAt = date(entry["resets_at"])
        return .progress(
            label: label,
            used: ProviderParse.clampPercent(100 - remaining),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: resetsAt == nil ? nil : periodMs
        )
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

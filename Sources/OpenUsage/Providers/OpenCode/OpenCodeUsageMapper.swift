import Foundation

/// Turns `GET /zen/go/v1/usage` into the three Go plan meters. The endpoint reports percent used
/// (same numbers as the OpenCode dashboard) plus an ISO reset time — not dollar spend — so each row
/// is a `.percent` progress meter.
enum OpenCodeUsageMapper {
    static func meterLines(_ response: HTTPResponse) throws -> [MetricLine] {
        guard let body = ProviderParse.jsonObject(response.body) else {
            throw OpenCodeUsageError.invalidResponse
        }
        return try meterLines(body: body)
    }

    static func meterLines(body: [String: Any]) throws -> [MetricLine] {
        guard let usage = body["usage"] as? [String: Any] else {
            throw OpenCodeUsageError.invalidResponse
        }
        return [
            try window(usage["rolling"], label: "Session", periodMs: MetricPeriod.sessionMs),
            try window(usage["weekly"], label: "Weekly", periodMs: MetricPeriod.weekMs),
            try window(usage["monthly"], label: "Monthly", periodMs: MetricPeriod.monthMs)
        ]
    }

    /// The upstream error discriminator (`AuthError`, `EntitlementError`, …), when the body is the
    /// documented `{ type, error: { type, message } }` shape. `nil` for HTML/Cloudflare/empty bodies.
    static func errorType(in response: HTTPResponse) -> String? {
        guard let body = ProviderParse.jsonObject(response.body),
              let error = body["error"] as? [String: Any],
              let type = (error["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !type.isEmpty
        else { return nil }
        return type
    }

    private static func window(_ raw: Any?, label: String, periodMs: Int) throws -> MetricLine {
        guard let object = raw as? [String: Any],
              let percent = ProviderParse.number(object["percent"])
        else {
            throw OpenCodeUsageError.invalidResponse
        }
        let resetsAt = (object["resetsAt"] as? String).flatMap(OpenUsageISO8601.date(from:))
        return .progress(
            label: label,
            used: ProviderParse.clampPercent(percent),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }
}

import Foundation
@testable import OpenUsage

enum CopilotTestFixtures {
    /// A RoutingHTTPClient answering with the first response whose URL-substring key matches; unmatched
    /// URLs 404.
    static func routedClient(
        _ routes: [(substring: String, response: HTTPResponse)]
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            routes.first(where: { request.url.absoluteString.contains($0.substring) })?.response
                ?? HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
    }

    /// The exact /copilot_internal/user shape of an org-managed Copilot Business seat from issue #839:
    /// plan is reported but every quota bucket is a zero-entitlement token-based-billing placeholder.
    /// Crucially, the premium bucket carries overage_permitted: true — the field that used to sneak an
    /// "Extra Usage: 0" row into the mapped lines and block the org-billing fallback.
    static func businessPlaceholderBody() -> [String: Any] {
        func bucket(_ id: String, overagePermitted: Bool) -> [String: Any] {
            [
                "overage_count": 0, "overage_entitlement": 0, "overage_permitted": overagePermitted,
                "percent_remaining": 100.0, "quota_id": id, "quota_remaining": 0.0, "unlimited": true,
                "has_quota": true, "quota_reset_at": 0, "token_based_billing": true,
                "remaining": 0, "entitlement": 0
            ]
        }
        return [
            "copilot_plan": "business",
            "token_based_billing": true,
            "quota_snapshots": [
                "chat": bucket("chat", overagePermitted: false),
                "completions": bucket("completions", overagePermitted: false),
                "premium_interactions": bucket("premium_interactions", overagePermitted: true)
            ]
        ]
    }

    /// The org billing usage summary from issue #839: one Copilot AI-unit item, fully covered by the
    /// included credits.
    static func orgSummaryBody() -> [String: Any] {
        [
            "timePeriod": ["year": 2026, "month": 7],
            "organization": "acme",
            "usageItems": [
                [
                    "product": "Copilot",
                    "sku": "copilot_ai_unit",
                    "unitType": "ai-units",
                    "pricePerUnit": 0.01,
                    "grossQuantity": 298.698546,
                    "grossAmount": 2.98698546,
                    "discountQuantity": 298.698546,
                    "discountAmount": 2.98698546,
                    "netQuantity": 0.0,
                    "netAmount": 0.0
                ]
            ]
        ]
    }

    static func okJSON(_ array: [[String: Any]]) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: try! JSONSerialization.data(withJSONObject: array)
        )
    }

    static func orgCount(_ lines: [MetricLine], _ label: String) -> Double? {
        value(lines, label: label, kind: .count)
    }

    static func orgDollars(_ lines: [MetricLine], _ label: String) -> Double? {
        value(lines, label: label, kind: .dollars)
    }

    static func paidBody() -> [String: Any] {
        [
            "copilot_plan": "pro",
            "quota_reset_date": "2099-01-15T00:00:00Z",
            "quota_snapshots": [
                "premium_interactions": [
                    "entitlement": 300,
                    "remaining": 123,
                    "percent_remaining": 41,
                    "quota_id": "premium"
                ],
                "chat": [
                    "entitlement": 1000,
                    "remaining": 950,
                    "percent_remaining": 95,
                    "quota_id": "chat"
                ]
            ]
        ]
    }

    static func ok(_ body: [String: Any]) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: try! JSONSerialization.data(withJSONObject: body)
        )
    }

    static func progress(
        _ lines: [MetricLine],
        _ label: String
    ) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(
            _,
            let used,
            let limit,
            _,
            let resetsAt,
            let periodDurationMs,
            _
        ) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    static func countValue(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first?.number
    }

    private static func value(
        _ lines: [MetricLine],
        label: String,
        kind: MetricKind
    ) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == kind })?.number
    }
}

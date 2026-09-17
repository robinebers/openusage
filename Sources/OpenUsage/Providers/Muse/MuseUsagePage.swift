import Foundation

/// Cookie-authenticated usage-page quota, ported from lassejlv's upstream PR
/// #1248 (robinebers/openusage). GET `dev.meta.ai/usage/` with the `llm_sess`
/// cookie; the server 302-redirects to the team's `team_id`/`project_id` URL
/// and embeds the full quota result (`subscription_quota_usage`) in the
/// returned HTML, so no GraphQL call — and no page-load tokens — are needed.
/// Bisected upstream 2026-09-11: `Accept: text/html` is the only header the
/// page needs beyond the cookie.
///
/// Sits behind our OAuth-first account endpoint and Responses probe: same
/// `MuseQuotaUsage` out, so `quotaLines`, plan names, and 429-attribution
/// memory all reuse. A page without the quota blob means the cookie was
/// rejected; every other shape problem is an invalid response.
struct MuseUsagePageClient: Sendable {
    static let usageURL = URL(string: "https://dev.meta.ai/usage/")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsagePage(sessionCookie: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: [
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Cookie": "\(MuseSessionCookieStore.cookieName)=\(sessionCookie)"
            ],
            timeout: 30
        ))
    }
}

/// Maps the server-rendered usage page into `MuseQuotaUsage`. Percentages are
/// derived (used / limit * 100); a missing window stays nil (unknown, not 0).
enum MuseUsagePageMapper {
    static func mapUsagePage(_ html: String) throws -> MuseQuotaUsage {
        guard let quota = extractQuotaObject(html) else {
            throw MuseQuotaError.unauthorized
        }
        return try mapQuota(quota)
    }

    static func mapQuota(_ quota: [String: Any]) throws -> MuseQuotaUsage {
        guard let windowUsed = ProviderParse.number(quota["window_weighted_used"]),
              let windowLimit = ProviderParse.number(quota["window_weighted_limit"]),
              let weeklyUsed = ProviderParse.number(quota["weekly_weighted_used"]),
              let weeklyLimit = ProviderParse.number(quota["weekly_weighted_limit"]),
              windowLimit > 0, weeklyLimit > 0
        else {
            throw MuseQuotaError.invalidResponse
        }
        return MuseQuotaUsage(
            tier: (quota["tier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            weeklyUsedPercent: weeklyUsed / weeklyLimit * 100,
            windowUsedPercent: windowUsed / windowLimit * 100,
            weeklyResetsAt: epochDate(quota["weekly_resets_at"]),
            windowResetsAt: epochDate(quota["window_resets_at"])
        )
    }

    /// Extract the `"subscription_quota_usage": {...}` object with a
    /// string/escape-aware balanced-brace scan (the page holds several
    /// preloader blobs; the quota key is unique).
    static func extractQuotaObject(_ html: String) -> [String: Any]? {
        guard let keyRange = html.range(of: "\"subscription_quota_usage\":"),
              let open = html[keyRange.upperBound...].firstIndex(of: "{"),
              let raw = balancedObject(html, from: open),
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func balancedObject(_ text: String, from open: String.Index) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[open...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func epochDate(_ value: Any?) -> Date? {
        guard let seconds = ProviderParse.number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

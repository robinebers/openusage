import Foundation

/// Reads one ChatGPT analytics report on UTC days. Token counts and supplemental workspace credits have
/// separate ledgers so a refused or rate-limited credits report cannot hide the primary counts.
struct CodexHistorySource: UsageHistorySource {
    enum Report: Sendable {
        case counts, teamCredits, enterpriseCredits

        static func workspaceCredits(for planType: String?) -> Self? {
            switch planType?.lowercased() {
            case "team", "self_serve_business_prolite", "self_serve_business_usage_based", "sci", "sci_plus":
                .teamCredits
            case "business", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise",
                 "edu", "edu_plus", "edu_pro":
                .enterpriseCredits
            default:
                nil
            }
        }
    }

    var client: CodexUsageClient
    var accessToken: String
    var chatGPTAccountID: String?
    var cardID: String
    var report: Report

    var calendar: Calendar { .utc }
    var rereadInterval: TimeInterval? { 3600 }

    func read(_ days: [Date], asOf: Date, calendar: Calendar) async -> (days: [Date: UsageDay], rateLimitedFor: TimeInterval?) {
        guard let first = days.min(), let last = days.max() else { return ([:], nil) }
        let dates = [URLQueryItem(name: "start_date", value: Self.date(first)), URLQueryItem(name: "end_date", value: Self.date(last))]
        let byDay = dates + [URLQueryItem(name: "group_by", value: "day")]
        let (path, query, parse): (String, [URLQueryItem], (Data) -> CodexUsageReports.Report?) = switch report {
        case .counts: ("analytics/daily-workspace-usage-counts", byDay + [URLQueryItem(name: "workspace_user", value: "true")],
                       CodexUsageReports.counts)
        case .teamCredits: ("usage/daily-workspace-user-token-usage-breakdown", byDay, CodexUsageReports.workspaceCredits)
        case .enterpriseCredits: ("usage/daily-workspace-user-credit-usage", dates + [URLQueryItem(name: "breakdown", value: "model")],
                                  CodexUsageReports.enterpriseCredits)
        }
        let tag = LogTag.plugin("codex")
        let response: HTTPResponse
        do {
            response = try await client.fetchReport(path, query: query, accessToken: accessToken, accountID: chatGPTAccountID)
        } catch {
            AppLog.warn(tag, "\(cardID) usage history: \(path) request failed")
            return ([:], nil)
        }
        if response.statusCode == 429 {
            let wait = response.retryAfter(now: asOf) ?? 3600
            AppLog.warn(tag, "\(cardID) usage history: \(path) rate limited; next read in \(Int(wait))s")
            return ([:], wait)
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(tag, "\(cardID) usage history: \(path) HTTP \(response.statusCode)")
            return ([:], nil)
        }
        guard let parsed = parse(response.body) else {
            AppLog.warn(tag, "\(cardID) usage history: \(path) invalid response")
            return ([:], nil)
        }
        let read = days.map { ($0, parsed.days[Self.date($0)] ?? parsed.quietDay) }
        return (Dictionary(uniqueKeysWithValues: read), nil)
    }

    /// A day start's UTC `yyyy-MM-dd`, the date format of the reports and their range parameters.
    static func date(_ day: Date) -> String { day.formatted(.iso8601.year().month().day()) }
}

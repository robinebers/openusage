import Foundation

/// Reads ChatGPT's usage history on UTC days from the reports the Codex client's Analytics view reads:
/// turns and tokens from the usage counts on every plan, and the credits charged from the report the plan's
/// account kind uses. Both are read once an hour.
struct CodexHistorySource: UsageHistorySource {
    /// The Codex client's account kinds, which pick the credits report (openai/codex `tui/src/analytics`).
    enum Plan {
        case personal
        /// Team-like plans and Sci.
        case team
        /// Business, education and enterprise plans.
        case enterprise

        init(planType: String?) {
            switch planType?.lowercased() {
            case "team", "self_serve_business_prolite", "self_serve_business_usage_based", "sci", "sci_plus":
                self = .team
            case "business", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise",
                 "edu", "edu_plus", "edu_pro":
                self = .enterprise
            default:
                self = .personal
            }
        }
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    var client: CodexUsageClient
    var accessToken: String
    var chatGPTAccountID: String?
    var cardID: String
    var plan: Plan

    var calendar: Calendar { Self.utc }
    var rereadInterval: TimeInterval? { 3600 }

    private enum Fetched: Sendable {
        case body(Data)
        case failed(String)
        case rateLimited(TimeInterval?)
    }

    func read(_ days: [Date], asOf: Date, calendar: Calendar) async -> (days: [Date: UsageDay], rateLimitedFor: TimeInterval?) {
        guard let first = days.min(), let last = days.max() else { return ([:], nil) }
        let dates = [URLQueryItem(name: "start_date", value: Self.date(first)), URLQueryItem(name: "end_date", value: Self.date(last))]
        let byDay = dates + [URLQueryItem(name: "group_by", value: "day")]
        let creditsReport: (path: String, query: [URLQueryItem], parse: (Data) -> CodexUsageReports.Report?) = switch plan {
        case .personal: ("usage/credit-usage-events", [], CodexUsageReports.creditEvents)
        case .team: ("usage/daily-workspace-user-token-usage-breakdown", byDay, CodexUsageReports.workspaceCredits)
        case .enterprise: ("usage/daily-workspace-user-credit-usage", dates + [URLQueryItem(name: "breakdown", value: "model")],
                           CodexUsageReports.enterpriseCredits)
        }
        let countsQuery = byDay + [URLQueryItem(name: "workspace_user", value: "true")]
        async let counts = fetch("analytics/daily-workspace-usage-counts", countsQuery, asOf: asOf)
        async let credits = fetch(creditsReport.path, creditsReport.query, asOf: asOf)
        let tag = LogTag.plugin("codex")
        switch (await counts, await credits) {
        case (.body(let countsBody), .body(let creditsBody)):
            guard let counted = CodexUsageReports.counts(countsBody), let charged = creditsReport.parse(creditsBody) else {
                AppLog.warn(tag, "\(cardID) usage history: invalid response")
                return ([:], nil)
            }
            let read = days.map { ($0, CodexUsageReports.day(Self.date($0), counts: counted, credits: charged)) }
            return (Dictionary(uniqueKeysWithValues: read), nil)
        case (.rateLimited(let retryAfter), _), (_, .rateLimited(let retryAfter)):
            let wait = retryAfter ?? 3600
            AppLog.warn(tag, "\(cardID) usage history: rate limited; next read in \(Int(wait))s")
            return ([:], wait)
        case (.failed(let reason), _), (_, .failed(let reason)):
            AppLog.warn(tag, "\(cardID) usage history: \(reason)")
            return ([:], nil)
        }
    }

    private func fetch(_ path: String, _ query: [URLQueryItem], asOf: Date) async -> Fetched {
        let response: HTTPResponse
        do {
            response = try await client.fetchReport(path, query: query, accessToken: accessToken, accountID: chatGPTAccountID)
        } catch {
            return .failed("\(path) request failed")
        }
        if response.statusCode == 429 { return .rateLimited(response.retryAfter(now: asOf)) }
        guard (200..<300).contains(response.statusCode) else { return .failed("\(path) HTTP \(response.statusCode)") }
        return .body(response.body)
    }

    /// A day start's UTC `yyyy-MM-dd`, the date format of the reports and their range parameters.
    static func date(_ day: Date) -> String { day.formatted(.iso8601.year().month().day()) }
}

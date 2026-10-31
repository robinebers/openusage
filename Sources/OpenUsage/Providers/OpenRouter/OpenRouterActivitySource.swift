import Foundation

/// Reads a Management key's `/api/v1/activity`, which ends at yesterday, so today is never read:
/// `?date=` when one day is due, else the last 30 finished UTC days, in one call either way.
struct OpenRouterActivitySource: UsageHistorySource {
    var client: OpenRouterUsageClient
    var apiKey: String
    var accountID: String

    var calendar: Calendar { OpenRouterUsageMapper.utc }
    /// Hourly, so history adds one call an hour per account.
    var rereadInterval: TimeInterval? { 3600 }

    func read(_ due: [Date], asOf: Date, calendar: Calendar) async -> (days: [Date: UsageDay], rateLimitedFor: TimeInterval?) {
        let tag = LogTag.plugin("openrouter")
        let days = due.filter { $0 < calendar.startOfDay(for: asOf) }
        guard !days.isEmpty else { return ([:], nil) }
        let response: HTTPResponse
        do {
            response = try await client.activity(apiKey: apiKey, date: days.count == 1 ? days.first : nil)
        } catch {
            AppLog.warn(tag, "\(accountID) activity request failed: \(error.localizedDescription)")
            return ([:], nil)
        }
        if response.statusCode == 429 {
            let wait = response.retryAfter(now: asOf) ?? 3600
            AppLog.warn(tag, "\(accountID) activity rate limited; next read in \(Int(wait))s")
            return ([:], wait)
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(tag, "\(accountID) activity returned HTTP \(response.statusCode)")
            return ([:], nil)
        }
        guard let read = OpenRouterUsageMapper.activityDays(response.body) else {
            AppLog.warn(tag, "\(accountID) activity response was invalid")
            return ([:], nil)
        }
        return (Dictionary(uniqueKeysWithValues: days.map { ($0, read[$0] ?? OpenRouterUsageMapper.quietDay) }), nil)
    }
}

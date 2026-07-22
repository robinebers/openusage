import Foundation

struct CommandCodeMappedUsage: Equatable, Sendable { var plan: String?; var lines: [MetricLine] }

struct CommandCodeSubscriptionContext: Equatable, Sendable {
    var planID: String; var planName: String; var currentPeriodStart: String
    var currentPeriodEnd: Date; var periodDurationMs: Int
}

/// Maps Command Code's account-wide billing APIs into the same dollar meters shown by its CLI.
/// The rolling windows report dollars already spent against a cap. Monthly usage is the amount drawn
/// from the subscription allocation; its limit is reconstructed from used + remaining monthly credit.
/// Purchased/free credits stay visible in Balance without inflating the subscription's Monthly meter.
/// Balance-only accounts omit subscription and rolling-window meters while keeping Balance and Requests.
enum CommandCodeUsageMapper {
    static let fiveHourPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = MetricPeriod.weekMs
    private static let usableSubscriptionStatuses = Set(["active", "trialing", "past_due"])

    private static let planNames: [String: String] = [
        "individual-go": "Go",
        "individual-pro": "Pro",
        "individual-provider": "Provider",
        "individual-max": "Max",
        "individual-ultra": "Ultra",
        "teams-pro": "Teams Pro"
    ]

    static func organizationID(from body: Data) throws -> String? {
        let payload: WhoamiPayload = try decode(body)
        guard payload.success else { throw CommandCodeUsageError.invalidResponse }
        guard let id = payload.org?.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return nil
        }
        return id
    }

    static func subscriptionContext(from body: Data) throws -> CommandCodeSubscriptionContext? {
        let payload: SubscriptionPayload = try decode(body)
        guard payload.success else { throw CommandCodeUsageError.invalidResponse }
        guard let data = payload.data else { return nil }
        guard let status = nonEmpty(data.status)?.lowercased() else {
            throw CommandCodeUsageError.invalidResponse
        }
        guard usableSubscriptionStatuses.contains(status) else { return nil }
        guard let planID = nonEmpty(data.planId),
              let currentPeriodStart = nonEmpty(data.currentPeriodStart),
              let currentPeriodEnd = nonEmpty(data.currentPeriodEnd),
              let start = OpenUsageISO8601.date(from: currentPeriodStart),
              let end = OpenUsageISO8601.date(from: currentPeriodEnd)
        else {
            throw CommandCodeUsageError.invalidResponse
        }

        let durationMs = end.timeIntervalSince(start) * 1000
        guard durationMs.isFinite, durationMs > 0, durationMs < Double(Int.max) else {
            throw CommandCodeUsageError.invalidResponse
        }
        return CommandCodeSubscriptionContext(
            planID: planID,
            planName: planName(for: planID),
            currentPeriodStart: currentPeriodStart,
            currentPeriodEnd: end,
            periodDurationMs: Int(durationMs.rounded())
        )
    }

    static func map(
        creditsBody: Data,
        summaryBody: Data,
        subscription: CommandCodeSubscriptionContext?
    ) throws -> CommandCodeMappedUsage {
        let credits: CreditsPayload = try decode(creditsBody)
        let summary: UsageSummaryPayload = try decode(summaryBody)

        let monthlyRemaining = try nonnegative(credits.credits.monthlyCredits)
        let purchasedRemaining = try nonnegative(credits.credits.purchasedCredits)
        let freeRemaining = try nonnegative(credits.credits.freeCredits)
        let monthlyUsed = try nonnegative(summary.totalMonthlyCredits)
        guard summary.totalCount >= 0 else { throw CommandCodeUsageError.invalidResponse }

        let balance = monthlyRemaining + purchasedRemaining + freeRemaining
        let monthlyLimit = monthlyUsed + monthlyRemaining
        guard balance.isFinite, monthlyLimit.isFinite else {
            throw CommandCodeUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        if credits.windowLimits?.limited == true {
            guard let fiveHour = credits.windowLimits?.fiveHour,
                  let weekly = credits.windowLimits?.weekly
            else {
                throw CommandCodeUsageError.invalidResponse
            }
            lines.append(try windowLine(
                label: "5-Hour",
                window: fiveHour,
                periodDurationMs: fiveHourPeriodMs
            ))
            lines.append(try windowLine(
                label: "Weekly",
                window: weekly,
                periodDurationMs: weeklyPeriodMs
            ))
        }
        if let subscription, monthlyLimit > 0 {
            lines.append(.progress(
                label: "Monthly",
                used: monthlyUsed,
                limit: monthlyLimit,
                format: .dollars,
                resetsAt: subscription.currentPeriodEnd,
                periodDurationMs: subscription.periodDurationMs
            ))
        }
        lines.append(.values(
            label: "Balance",
            values: [MetricValue(number: balance, kind: .dollars)]
        ))
        lines.append(.values(
            label: "Requests",
            values: [MetricValue(number: Double(summary.totalCount), kind: .count, label: "requests")]
        ))
        return CommandCodeMappedUsage(plan: subscription?.planName, lines: lines)
    }

    static func planName(for planID: String) -> String {
        let normalized = planID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if let key = planNames.keys.sorted(by: { $0.count > $1.count }).first(where: {
            normalized == $0 || normalized.hasPrefix($0 + "-")
        }),
           let name = planNames[key] {
            return name
        }
        let readable = normalized
            .split(separator: "-")
            .map { String($0).capitalized }
            .joined(separator: " ")
        return readable.isEmpty ? planID : readable
    }

    private static func windowLine(
        label: String,
        window: WindowPayload,
        periodDurationMs: Int
    ) throws -> MetricLine {
        let used = try nonnegative(window.used)
        let cap = try nonnegative(window.cap)
        guard cap > 0,
              window.resetAt.isFinite,
              window.resetAt >= 0
        else {
            throw CommandCodeUsageError.invalidResponse
        }
        return .progress(
            label: label,
            used: used,
            limit: cap,
            format: .dollars,
            resetsAt: Date(timeIntervalSince1970: window.resetAt / 1000),
            periodDurationMs: periodDurationMs
        )
    }

    private static func nonnegative(_ value: Double) throws -> Double {
        guard value.isFinite, value >= 0 else { throw CommandCodeUsageError.invalidResponse }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func decode<T: Decodable>(_ body: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: body)
        } catch {
            throw CommandCodeUsageError.invalidResponse
        }
    }
}

private struct WhoamiPayload: Decodable {
    struct Organization: Decodable { var id: String? }
    var success: Bool; var org: Organization?
}

private struct SubscriptionPayload: Decodable {
    struct Details: Decodable {
        var status: String; var currentPeriodStart: String?; var currentPeriodEnd: String?; var planId: String?
    }
    var success: Bool; var data: Details?
}
private struct CreditsPayload: Decodable {
    struct Credits: Decodable {
        var monthlyCredits: Double; var purchasedCredits: Double; var freeCredits: Double
    }
    var credits: Credits; var windowLimits: WindowLimitsPayload?
}

private struct WindowLimitsPayload: Decodable {
    var limited: Bool; var fiveHour: WindowPayload?; var weekly: WindowPayload?
}
private struct WindowPayload: Decodable {
    var used: Double; var cap: Double; var resetAt: Double
}
private struct UsageSummaryPayload: Decodable {
    var totalCount: Int; var totalMonthlyCredits: Double
}

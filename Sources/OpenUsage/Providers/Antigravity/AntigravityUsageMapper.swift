import Foundation

enum AntigravityUsageMapper {
    static let summaryBuckets: [(bucketID: String, label: String, periodMs: Int)] = [
        ("gemini-5h", AntigravityMetric.sessionLabel, MetricPeriod.sessionMs),
        ("gemini-weekly", AntigravityMetric.weeklyLabel, MetricPeriod.weekMs),
        ("3p-5h", AntigravityMetric.claudeLabel, MetricPeriod.sessionMs),
        ("3p-weekly", AntigravityMetric.claudeWeeklyLabel, MetricPeriod.weekMs)
    ]

    static func parseQuotaSummaries(_ bodies: [Data]) -> [MetricLine]? {
        let groupLists = bodies.compactMap { data -> [QuotaSummaryGroup]? in
            guard let groups = summaryGroups(data) else {
                AppLog.warn(LogTag.plugin("antigravity"), "quota summary response has no decodable groups; treating as not-a-summary")
                return nil
            }
            return groups
        }
        guard !groupLists.isEmpty else { return nil }

        var pooled: [String: (fraction: Double, resetTime: Date?)] = [:]
        for bucket in groupLists.joined().filter({ $0.displayName != argonGroupName }).flatMap({ $0.buckets ?? [] }) {
            guard let id = bucket.bucketId, summaryBuckets.contains(where: { $0.bucketID == id }) else {
                AppLog.warn(LogTag.plugin("antigravity"), "quota summary: skipping unrecognized bucket id '\(bucket.bucketId ?? "<absent>")'")
                continue
            }
            guard pooled[id] == nil else { continue }
            guard let fraction = bucket.remainingFraction, fraction.isFinite else {
                AppLog.warn(LogTag.plugin("antigravity"), "quota summary: bucket '\(id)' has no usable remainingFraction; dropping its line")
                continue
            }
            pooled[id] = (fraction, bucket.resetTime.flatMap { OpenUsageISO8601.date(from: $0) })
        }

        var lines: [MetricLine] = summaryBuckets.compactMap { spec in
            guard let entry = pooled[spec.bucketID] else { return nil }
            return line(pool: spec.label, fraction: entry.fraction, resetTime: entry.resetTime, periodMs: spec.periodMs)
        }
        if let argon = groupLists.lazy.compactMap(argonWeeklyLine).first {
            let index = lines.firstIndex {
                $0.label == AntigravityMetric.claudeLabel || $0.label == AntigravityMetric.claudeWeeklyLabel
            } ?? lines.endIndex
            lines.insert(argon, at: index)
        }
        return lines
    }

    private static let argonGroupName = "Gemini 4 Argon"

    private static func argonWeeklyLine(_ groups: [QuotaSummaryGroup]) -> MetricLine? {
        let argonGroups = groups.filter { $0.displayName == argonGroupName }
        guard !argonGroups.isEmpty else { return nil }
        let buckets = argonGroups.flatMap { $0.buckets ?? [] }
        for bucket in buckets where bucket.window != "weekly" {
            AppLog.warn(LogTag.plugin("antigravity"), "Argon quota has unsupported window '\(bucket.window ?? "<absent>")'; skipping its bucket")
        }
        let weekly = buckets.filter { $0.window == "weekly" }
        guard weekly.count == 1, let bucket = weekly.first,
              let id = bucket.bucketId?.nilIfEmpty,
              !summaryBuckets.contains(where: { $0.bucketID == id }) else {
            AppLog.warn(LogTag.plugin("antigravity"), "Argon quota group has no unambiguous separate weekly bucket; dropping its line")
            return nil
        }
        guard !bucket.hasInvalidDisabledFlag else {
            AppLog.warn(LogTag.plugin("antigravity"), "Argon weekly quota has an unusable disabled flag; dropping its line")
            return nil
        }
        guard bucket.disabled != true else { return nil }
        guard let fraction = bucket.remainingFraction, fraction.isFinite else {
            AppLog.warn(LogTag.plugin("antigravity"), "Argon weekly quota has no usable remainingFraction; dropping its line")
            return nil
        }
        return line(
            pool: AntigravityMetric.argonWeeklyLabel,
            fraction: fraction,
            resetTime: bucket.resetTime.flatMap { OpenUsageISO8601.date(from: $0) },
            periodMs: MetricPeriod.weekMs
        )
    }

    static func isCompleteSummary(_ data: Data) -> Bool {
        guard let groups = summaryGroups(data) else { return false }
        let shared = groups.filter { $0.displayName != argonGroupName }
        let usable = Set(shared.flatMap { $0.buckets ?? [] }.compactMap { bucket in
            bucket.remainingFraction?.isFinite == true ? bucket.bucketId : nil
        })
        return summaryBuckets.allSatisfy { usable.contains($0.bucketID) }
    }

    private static func summaryGroups(_ data: Data) -> [QuotaSummaryGroup]? {
        guard let envelope = try? JSONDecoder().decode(QuotaSummaryEnvelope.self, from: data) else { return nil }
        return envelope.response?.groups ?? envelope.groups
    }

    static let paidTierPlans = ["g1-pro-tier": "Google AI Pro", "g1-ultra-tier": "Google AI Ultra", "g1-ultra-lite-tier": "Google AI Ultra Lite"]

    static func parseLoadCodeAssistPlan(_ data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(CCLoadEnvelope.self, from: data) else { return nil }
        if let id = envelope.paidTier?.id, let plan = paidTierPlans[id] { return plan }
        return formatPlan(envelope.paidTier?.name ?? envelope.currentTier?.name)
    }

    static func parseProject(_ data: Data) -> String? {
        (try? JSONDecoder().decode(CCLoadEnvelope.self, from: data))?.cloudaicompanionProject?.nilIfEmpty
    }

    static func line(pool: String, fraction: Double, resetTime: Date?, periodMs: Int) -> MetricLine {
        let clamped = max(0, min(1, fraction))
        let used = ((1 - clamped) * 100).rounded()
        return .percent(pool, used, resetsAt: resetTime, periodMs: periodMs)
    }

    static func formatPlan(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        for tier in ["Ultra Lite", "Ultra", "Pro"] where trimmed.lowercased().contains(tier.lowercased()) {
            return "Google AI \(tier)"
        }
        return trimmed.titleCased(separator: \.isWhitespace)
    }
}

private struct QuotaSummaryEnvelope: Decodable {
    let response: QuotaSummaryRoot?
    let groups: [QuotaSummaryGroup]?
}

private struct QuotaSummaryRoot: Decodable {
    let groups: [QuotaSummaryGroup]?
}

private struct QuotaSummaryGroup: Decodable {
    let displayName: String?
    let buckets: [QuotaSummaryBucket]?

    private enum CodingKeys: String, CodingKey { case displayName, buckets }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        buckets = try container.decodeIfPresent([QuotaSummaryBucket].self, forKey: .buckets)
    }
}

private struct QuotaSummaryBucket: Decodable {
    let bucketId: String?
    let remainingFraction: Double?
    let resetTime: String?
    let window: String?
    let disabled: Bool?
    let hasInvalidDisabledFlag: Bool

    private enum CodingKeys: String, CodingKey { case bucketId, remainingFraction, resetTime, window, disabled }

    init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        bucketId = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .bucketId)) ?? nil }
        remainingFraction = container.flatMap { (try? $0.decodeIfPresent(Double.self, forKey: .remainingFraction)) ?? nil }
        resetTime = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .resetTime)) ?? nil }
        window = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .window)) ?? nil }
        do {
            disabled = try container?.decodeIfPresent(Bool.self, forKey: .disabled)
            hasInvalidDisabledFlag = false
        } catch {
            disabled = nil
            hasInvalidDisabledFlag = true
        }
    }
}

private struct CCLoadEnvelope: Decodable {
    let cloudaicompanionProject: String?
    let currentTier: Tier?
    let paidTier: Tier?

    struct Tier: Decodable {
        let id: String?
        let name: String?
    }
}

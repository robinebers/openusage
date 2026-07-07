import Foundation

struct QoderUsageInfo: Decodable, Equatable, Sendable {
    var totalUsagePercentage: Double?
    var expiresAt: Double?
    var userQuota: QoderUsageQuotaBucket?
    var addOnQuota: QoderUsageAddOnQuotaBucket?
    var orgResourcePackage: QoderUsageOrgResourcePackage?
    var isQuotaExceeded: Bool?
}

struct QoderUsageQuotaBucket: Decodable, Equatable, Sendable {
    var total: Double?
    var used: Double?
    var remaining: Double?
    var percentage: Double?
    var unit: String?
}

struct QoderUsageAddOnQuotaBucket: Decodable, Equatable, Sendable {
    var total: Double?
    var used: Double?
    var remaining: Double?
    var percentage: Double?
    var unit: String?
    var detailUrl: String?
}

struct QoderUsageOrgResourcePackage: Decodable, Equatable, Sendable {
    var used: Double?
    var cap: Double?
    var remaining: Double?
    var percentage: Double?
    var available: Bool?
    var unit: String?
}

enum QoderMetric {
    static let monthly = "Monthly"
    static let addOnCredits = "Add-on Credits"
    static let orgCredits = "Org Credits"
}

enum QoderUsageMapper {
    static func map(_ usage: QoderUsageInfo) -> [MetricLine] {
        var lines: [MetricLine] = []
        let resetsAt = resetDate(from: usage.expiresAt)

        if let quota = usage.userQuota,
           let line = monthlyLine(quota, resetsAt: resetsAt) {
            lines.append(line)
        }
        if let quota = usage.addOnQuota,
           let line = quotaLine(label: QoderMetric.addOnCredits, bucket: quota, resetsAt: resetsAt) {
            lines.append(line)
        }
        if let package = usage.orgResourcePackage,
           let line = orgPackageLine(package, resetsAt: resetsAt) {
            lines.append(line)
        }
        MetricLine.appendNoDataIfNeeded(&lines)
        return lines
    }

    private static func monthlyLine(_ bucket: QoderUsageQuotaBucket, resetsAt: Date?) -> MetricLine? {
        guard let usedPercent = usedPercentage(bucket) else { return nil }
        return .progress(
            label: QoderMetric.monthly,
            used: ProviderParse.clampPercent(usedPercent),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt
        )
    }

    private static func usedPercentage(_ bucket: QoderUsageQuotaBucket) -> Double? {
        if let percentage = bucket.percentage { return percentage }
        guard let used = usedValue(used: bucket.used, total: bucket.total, remaining: bucket.remaining),
              let total = totalValue(total: bucket.total, used: bucket.used, remaining: bucket.remaining),
              total > 0 else {
            return nil
        }
        return used / total * 100
    }

    private static func quotaLine(label: String, bucket: QoderUsageAddOnQuotaBucket, resetsAt: Date?) -> MetricLine? {
        guard let used = usedValue(used: bucket.used, total: bucket.total, remaining: bucket.remaining),
              let total = totalValue(total: bucket.total, used: bucket.used, remaining: bucket.remaining) else {
            return nil
        }
        return .progress(
            label: label,
            used: max(0, used),
            limit: max(0, total),
            format: .count(suffix: bucket.unit?.nilIfEmpty ?? "credits"),
            resetsAt: resetsAt
        )
    }

    private static func orgPackageLine(_ package: QoderUsageOrgResourcePackage, resetsAt: Date?) -> MetricLine? {
        if package.available == false { return nil }
        guard let used = package.used,
              let cap = package.cap else {
            return nil
        }
        return .progress(
            label: QoderMetric.orgCredits,
            used: max(0, used),
            limit: max(0, cap),
            format: .count(suffix: package.unit?.nilIfEmpty ?? "credits"),
            resetsAt: resetsAt
        )
    }

    private static func usedValue(used: Double?, total: Double?, remaining: Double?) -> Double? {
        if let used { return used }
        guard let total, let remaining else { return nil }
        return total - remaining
    }

    private static func totalValue(total: Double?, used: Double?, remaining: Double?) -> Double? {
        if let total { return total }
        guard let used, let remaining else { return nil }
        return used + remaining
    }

    private static func resetDate(from raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}

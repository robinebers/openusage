import Foundation

/// Turns Antigravity's quota responses into the app's metric vocabulary.
///
/// The source is the `RetrieveUserQuotaSummary` RPC (`parseQuotaSummaries`): the shared Gemini and
/// non-Gemini pools each have rolling 5-hour and weekly windows, and eligible accounts have a separate
/// Argon weekly quota.
enum AntigravityUsageMapper {
    // MARK: - Quota summary

    /// The four shared-pool buckets, matched by **exact `bucketId` only** —
    /// a future bucket (e.g. `gemini-image-5h`) must never silently join a pool, and pool identity is
    /// never inferred from `displayName`/`window`. Argon's distinct group is handled separately below.
    static let summaryBuckets: [(bucketID: String, label: String, periodMs: Int)] = [
        ("gemini-5h", AntigravityMetric.sessionLabel, MetricPeriod.sessionMs),
        ("gemini-weekly", AntigravityMetric.weeklyLabel, MetricPeriod.weekMs),
        ("3p-5h", AntigravityMetric.claudeLabel, MetricPeriod.sessionMs),
        ("3p-weekly", AntigravityMetric.claudeWeeklyLabel, MetricPeriod.weekMs)
    ]

    /// `RetrieveUserQuotaSummary` bodies (one per Cloud Code host) merged by bucket id into up to five
    /// meters, ordered Session, Weekly, Argon Weekly, Claude, Claude Weekly: the first usable bucket for
    /// each id wins. One host can omit a whole pool (seen 2026-10-17: the daily host returned only the
    /// Claude group), so no single body is trusted to be complete. Each body may be the LS envelope
    /// (`{"response": {"groups": …}}`) or the bare remote payload (`{"groups": …}`).
    ///
    /// Nil means no body is a summary (undecodable / no `groups` anywhere). Buckets decode leniently
    /// (one malformed bucket never voids the envelope); a bucket with a missing/unusable
    /// `remainingFraction` drops its line (the row reads "No data") rather than fabricating 0% or 100%.
    static func parseQuotaSummaries(_ bodies: [Data]) -> [MetricLine]? {
        let groupLists = bodies.compactMap { data -> [QuotaSummaryGroup]? in
            guard let groups = summaryGroups(data) else {
                // Callers only parse 2xx bodies, so an undecodable one is schema drift — say so loudly.
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
            guard pooled[id] == nil else { continue } // duplicate bucket id — first one wins
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
        // Argon is judged per body: combining two hosts' Argon groups would read as an ambiguous bucket.
        if let argon = groupLists.lazy.compactMap(argonWeeklyLine).first {
            let index = lines.firstIndex {
                $0.label == AntigravityMetric.claudeLabel || $0.label == AntigravityMetric.claudeWeeklyLabel
            } ?? lines.endIndex
            lines.insert(argon, at: index)
        }
        return lines
    }

    /// Match Argon's separate group and explicit weekly window. Require one unambiguous bucket;
    /// shared-pool groups still use only the known exact IDs above.
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

    /// Whether one summary body already has a usable fraction for all four shared-pool buckets, so no
    /// other host's answer could add or change those meters under the first-wins merge. Argon is not
    /// required: accounts without it never report it.
    static func isCompleteSummary(_ data: Data) -> Bool {
        guard let groups = summaryGroups(data) else { return false }
        // Same group rule as the merge: a shared bucket id inside the Argon group never yields a meter.
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

    // MARK: - Plan and project (`loadCodeAssist`)

    /// Google One subscription tiers by `paidTier.id`, which is stabler than the display name, each under
    /// the name Google sells it as.
    static let paidTierPlans = ["g1-pro-tier": "Google AI Pro", "g1-ultra-tier": "Google AI Ultra", "g1-ultra-lite-tier": "Google AI Ultra Lite"]

    /// Cloud Code `loadCodeAssist` → plan name: a known `paidTier.id` first, then the paid tier's name,
    /// then the current tier's name.
    static func parseLoadCodeAssistPlan(_ data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(CCLoadEnvelope.self, from: data) else { return nil }
        if let id = envelope.paidTier?.id, let plan = paidTierPlans[id] { return plan }
        return formatPlan(envelope.paidTier?.name ?? envelope.currentTier?.name)
    }

    static func parseProject(_ data: Data) -> String? {
        (try? JSONDecoder().decode(CCLoadEnvelope.self, from: data))?.cloudaicompanionProject?.nilIfEmpty
    }

    // MARK: - Line building

    static func line(pool: String, fraction: Double, resetTime: Date?, periodMs: Int) -> MetricLine {
        let clamped = max(0, min(1, fraction))
        let used = (1 - clamped) * 100
        return .progress(
            label: pool,
            used: used.rounded(), // keep whole percents so a fresh window reads 0 and the fresh-window treatment applies
            limit: 100,
            format: .percent,
            resetsAt: resetTime,
            periodDurationMs: periodMs
        )
    }

    /// Normalize a raw plan/tier string to the name Google sells the subscription as: "Google AI Pro",
    /// "Google AI Ultra" or "Google AI Ultra Lite", whether the tier name says so itself or buries the
    /// tier word ("Gemini Code Assist in Google One AI Pro"). Any other name, such as the free tier's
    /// "Antigravity Starter Quota", is Google's own and passes through.
    static func formatPlan(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        for tier in ["Ultra Lite", "Ultra", "Pro"] where trimmed.lowercased().contains(tier.lowercased()) {
            return "Google AI \(tier)"
        }
        return trimmed.titleCased(separator: \.isWhitespace)
    }
}

// MARK: - Wire types (the documented response shapes; validated only at this boundary)

/// `RetrieveUserQuotaSummary`, both envelopes: the LS wraps the payload in `{"response": {...}}`,
/// the remote Cloud Code endpoint returns it bare. Every field is optional — third-party parsers have
/// already regressed by assuming absent fields (defaulting a missing `remainingFraction` to "full").
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
        // A malformed optional name must not invalidate otherwise usable shared-pool buckets.
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        buckets = try container.decodeIfPresent([QuotaSummaryBucket].self, forKey: .buckets)
    }
}

/// A bucket that never fails its containing array: a malformed element (not an object, or a field of
/// the wrong type) decodes to nil fields instead of failing the whole summary. The mapper then drops
/// the unusable bucket with a warning and keeps the rest.
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
            // Missing/null flags retain protobuf's default; a malformed flag cannot establish access.
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

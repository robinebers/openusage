import Foundation

/// One model's quota as returned by any source (LS, Cloud Code models, Cloud Code buckets), normalized
/// before pooling. `remainingFraction` is 0…1 (1 = full); a model with no quota info is treated as
/// depleted (0 remaining).
struct AntigravityModelConfig: Sendable, Equatable {
    var label: String
    var modelID: String?
    var remainingFraction: Double
    var resetTime: Date?
}

/// Turns Antigravity's quota responses into the app's metric vocabulary.
///
/// The authoritative source is the `RetrieveUserQuotaSummary` RPC (`parseQuotaSummary`): two pools
/// (Gemini, shown as "Session"/"Weekly"; Claude = every non-Gemini model incl. GPT-OSS), each with a
/// rolling 5-hour and a weekly window — up to four meters. Builds without that RPC fall back to the
/// legacy per-model endpoints, whose fine-grained models collapse into the two 5h pool meters
/// ("Session", "Claude"), each keeping the
/// worst (lowest) remaining fraction in its pool; the legacy data is 5h-only, so the weekly meters
/// read "No data" there.
enum AntigravityUsageMapper {
    /// Internal/duplicate model IDs that should never surface as a meter. Matched against the model ID
    /// (LS `modelOrAlias.model`, Cloud Code `model`/key); the Cloud Code path also drops `isInternal`.
    static let modelBlacklist: Set<String> = [
        "MODEL_CHAT_20706", "MODEL_CHAT_23310",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH", "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE", "MODEL_GOOGLE_GEMINI_2_5_PRO",
        "MODEL_PLACEHOLDER_M19", "MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M12"
    ]

    // MARK: - Quota summary (the authoritative source)

    /// The four pool buckets `RetrieveUserQuotaSummary` reports, matched by **exact `bucketId` only** —
    /// a future bucket (e.g. `gemini-image-5h`) must never silently join a pool, and pool identity is
    /// never inferred from `displayName`/`window`.
    static let summaryBuckets: [(bucketID: String, label: String, periodMs: Int)] = [
        ("gemini-5h", AntigravityMetric.sessionLabel, MetricPeriod.sessionMs),
        ("gemini-weekly", AntigravityMetric.weeklyLabel, MetricPeriod.weekMs),
        ("3p-5h", AntigravityMetric.claudeLabel, MetricPeriod.sessionMs),
        ("3p-weekly", AntigravityMetric.claudeWeeklyLabel, MetricPeriod.weekMs)
    ]

    /// `RetrieveUserQuotaSummary` → up to four pool meters, ordered Session, Weekly, Claude,
    /// Claude Weekly. Accepts both the LS envelope (`{"response": {"groups": …}}`) and the bare remote
    /// payload (`{"groups": …}`).
    ///
    /// Nil means "not a summary" (undecodable body / no `groups` anywhere) and the caller may fall back
    /// to the legacy endpoints. A non-nil result — even an empty one — is authoritative: the legacy
    /// path fabricates "fully used" from missing quota info, so a parsed summary must never fall
    /// through to it. Buckets decode leniently (one malformed bucket never voids the envelope); a
    /// bucket with a missing/unusable `remainingFraction` drops its line (the row reads "No data")
    /// rather than fabricating 0% or 100%.
    static func parseQuotaSummary(_ data: Data) -> [MetricLine]? {
        guard let envelope = try? JSONDecoder().decode(QuotaSummaryEnvelope.self, from: data),
              let groups = envelope.response?.groups ?? envelope.groups
        else {
            // Callers only parse 2xx bodies, so an undecodable one is schema drift — say so loudly.
            AppLog.warn(LogTag.plugin("antigravity"), "quota summary response has no decodable groups; treating as not-a-summary")
            return nil
        }

        var pooled: [String: (fraction: Double, resetTime: Date?)] = [:]
        for bucket in groups.flatMap({ $0.buckets ?? [] }) {
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

        return summaryBuckets.compactMap { spec in
            guard let entry = pooled[spec.bucketID] else { return nil }
            return line(pool: spec.label, fraction: entry.fraction, resetTime: entry.resetTime, periodMs: spec.periodMs)
        }
    }

    // MARK: - Response parsing (legacy per-model endpoints)

    /// LS `GetUserStatus` → plan name + model configs. Nil when the body has no `userStatus`.
    static func parseUserStatus(_ data: Data) -> (plan: String?, configs: [AntigravityModelConfig])? {
        guard let envelope = try? JSONDecoder().decode(LSUserStatusEnvelope.self, from: data),
              let status = envelope.userStatus
        else {
            return nil
        }
        // Prefer Google's own `userTier` over the Windsurf-inherited `planInfo.planName` (which reads
        // "Pro" for every paid tier).
        let plan = formatPlan(status.userTier?.name ?? status.planStatus?.planInfo?.planName)
        let configs = (status.cascadeModelConfigData?.clientModelConfigs ?? []).compactMap(config(fromLS:))
        return (plan, configs)
    }

    /// LS `GetCommandModelConfigs` fallback → model configs only (no plan). Nil when absent.
    static func parseCommandModelConfigs(_ data: Data) -> [AntigravityModelConfig]? {
        guard let envelope = try? JSONDecoder().decode(LSCommandConfigsEnvelope.self, from: data),
              let configs = envelope.clientModelConfigs
        else {
            return nil
        }
        return configs.compactMap(config(fromLS:))
    }

    /// Cloud Code `fetchAvailableModels` → model configs (drops `isInternal`, empty-label models).
    static func parseCloudCodeModels(_ data: Data) -> [AntigravityModelConfig] {
        guard let envelope = try? JSONDecoder().decode(CCModelsEnvelope.self, from: data),
              let models = envelope.models
        else {
            return []
        }
        return models.compactMap { key, model -> AntigravityModelConfig? in
            if model.isInternal == true { return nil }
            guard let label = (model.displayName?.nilIfEmpty) ?? (model.label?.nilIfEmpty) else { return nil }
            return config(label: label, modelID: model.model?.nilIfEmpty ?? key, quota: model.quotaInfo)
        }
    }

    /// Cloud Code `retrieveUserQuota` → buckets keyed by raw model id (e.g. `gemini-3-pro-preview`).
    static func parseQuotaBuckets(_ data: Data) -> [AntigravityModelConfig] {
        guard let envelope = try? JSONDecoder().decode(CCQuotaEnvelope.self, from: data),
              let buckets = envelope.buckets
        else {
            return []
        }
        return buckets.compactMap { bucket -> AntigravityModelConfig? in
            guard let id = bucket.modelId?.nilIfEmpty else { return nil }
            return AntigravityModelConfig(
                label: id,
                modelID: id,
                remainingFraction: bucket.remainingFraction ?? 0,
                resetTime: bucket.resetTime.flatMap { OpenUsageISO8601.date(from: $0) }
            )
        }
    }

    /// Cloud Code `loadCodeAssist` → plan name (paid tier preferred over current tier).
    static func parseLoadCodeAssistPlan(_ data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(CCLoadEnvelope.self, from: data) else { return nil }
        return formatPlan(envelope.paidTier?.name ?? envelope.currentTier?.name)
    }

    static func parseProject(_ data: Data) -> String? {
        (try? JSONDecoder().decode(CCLoadEnvelope.self, from: data))?.cloudaicompanionProject?.nilIfEmpty
    }

    // MARK: - Line building (legacy pooling)

    /// Collapse model configs into the two quota-pool meters, keeping the worst fraction per pool and
    /// ordering the Gemini pool ("Session") before Claude. Blacklisted and empty-label models are dropped.
    static func buildLines(_ configs: [AntigravityModelConfig]) -> [MetricLine] {
        var pooled: [String: (fraction: Double, resetTime: Date?)] = [:]
        for config in configs {
            let label = config.label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            if let id = config.modelID, modelBlacklist.contains(id) { continue }

            let pool = poolLabel(normalizeLabel(label))
            if let existing = pooled[pool] {
                // Worst-case wins; ties keep the first seen.
                if config.remainingFraction < existing.fraction {
                    pooled[pool] = (config.remainingFraction, config.resetTime)
                }
            } else {
                pooled[pool] = (config.remainingFraction, config.resetTime)
            }
        }

        return pooled
            .sorted { sortKey($0.key) < sortKey($1.key) }
            .map { line(pool: $0.key, fraction: $0.value.fraction, resetTime: $0.value.resetTime, periodMs: MetricPeriod.sessionMs) }
    }

    static func line(pool: String, fraction: Double, resetTime: Date?, periodMs: Int) -> MetricLine {
        let clamped = max(0, min(1, fraction))
        let used = (1 - clamped) * 100
        return .progress(
            label: pool,
            used: used.rounded(), // keep whole percents so a fresh window reads 0 and "Not started" works
            limit: 100,
            format: .percent,
            resetsAt: resetTime,
            periodDurationMs: periodMs
        )
    }

    // MARK: - Pooling helpers (pure)

    /// "Gemini 3 Pro (High)" → "Gemini 3 Pro" — strip a trailing parenthetical variant.
    static func normalizeLabel(_ label: String) -> String {
        if let range = label.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
            return String(label[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return label.trimmingCharacters(in: .whitespaces)
    }

    static func poolLabel(_ normalizedLabel: String) -> String {
        // Pro and Flash draw from one shared pool since Antigravity's 2026-05-19 quota merge, so every
        // Gemini model (Pro, Flash, Ultra, bare names) maps to the single "Session" meter; Claude,
        // GPT-OSS, and any other non-Gemini model share the other pool.
        normalizedLabel.lowercased().contains("gemini") ? AntigravityMetric.sessionLabel : AntigravityMetric.claudeLabel
    }

    static func sortKey(_ poolLabel: String) -> String {
        // The Gemini pool ("Session") before Claude, matching the widget declaration order.
        poolLabel == AntigravityMetric.sessionLabel ? "0_\(poolLabel)" : "1_\(poolLabel)"
    }

    /// Normalize a raw plan/tier string to a short label. LS returns "Google AI Pro" (strip the prefix,
    /// keep the tail); Cloud Code returns "Gemini Code Assist in Google One AI Pro" (pull the tier word).
    static func formatPlan(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        if let range = trimmed.range(of: "Google AI "), range.lowerBound == trimmed.startIndex {
            return String(trimmed[range.upperBound...]).titleCased(separator: \.isWhitespace)
        }
        for keyword in ["Ultra", "Pro", "Free"] where trimmed.lowercased().contains(keyword.lowercased()) {
            return keyword
        }
        return trimmed.titleCased(separator: \.isWhitespace)
    }

    private static func config(fromLS model: LSModelConfig) -> AntigravityModelConfig? {
        config(label: model.label, modelID: model.modelOrAlias?.model, quota: model.quotaInfo)
    }

    private static func config(label: String?, modelID: String?, quota: AntigravityQuotaInfo?) -> AntigravityModelConfig? {
        guard let label = label?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return nil }
        return AntigravityModelConfig(
            label: label,
            modelID: modelID,
            remainingFraction: quota?.remainingFraction ?? 0,
            resetTime: quota?.resetTime.flatMap { OpenUsageISO8601.date(from: $0) }
        )
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
    let buckets: [QuotaSummaryBucket]?
}

/// A bucket that never fails its containing array: a malformed element (not an object, or a field of
/// the wrong type) decodes to nil fields instead of throwing the whole summary into the legacy
/// fallback. The mapper then drops the unusable bucket with a warning and keeps the rest.
private struct QuotaSummaryBucket: Decodable {
    let bucketId: String?
    let remainingFraction: Double?
    let resetTime: String?

    private enum CodingKeys: String, CodingKey { case bucketId, remainingFraction, resetTime }

    init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        bucketId = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .bucketId)) ?? nil }
        remainingFraction = container.flatMap { (try? $0.decodeIfPresent(Double.self, forKey: .remainingFraction)) ?? nil }
        resetTime = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .resetTime)) ?? nil }
    }
}

private struct AntigravityQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}

private struct LSModelConfig: Decodable {
    let label: String?
    let modelOrAlias: ModelOrAlias?
    let quotaInfo: AntigravityQuotaInfo?

    struct ModelOrAlias: Decodable { let model: String? }
}

private struct LSUserStatusEnvelope: Decodable {
    let userStatus: UserStatus?

    struct UserStatus: Decodable {
        let userTier: Tier?
        let planStatus: PlanStatus?
        let cascadeModelConfigData: CascadeData?
    }
    struct Tier: Decodable { let name: String? }
    struct PlanStatus: Decodable { let planInfo: PlanInfo? }
    struct PlanInfo: Decodable { let planName: String? }
    struct CascadeData: Decodable { let clientModelConfigs: [LSModelConfig]? }
}

private struct LSCommandConfigsEnvelope: Decodable {
    let clientModelConfigs: [LSModelConfig]?
}

private struct CCModelsEnvelope: Decodable {
    let models: [String: CCModel]?

    struct CCModel: Decodable {
        let model: String?
        let displayName: String?
        let label: String?
        let isInternal: Bool?
        let quotaInfo: AntigravityQuotaInfo?
    }
}

private struct CCLoadEnvelope: Decodable {
    let cloudaicompanionProject: String?
    let currentTier: Tier?
    let paidTier: Tier?

    struct Tier: Decodable { let name: String? }
}

private struct CCQuotaEnvelope: Decodable {
    let buckets: [Bucket]?

    struct Bucket: Decodable {
        let modelId: String?
        let remainingFraction: Double?
        let resetTime: String?
    }
}

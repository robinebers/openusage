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

/// Turns Antigravity's per-model quota responses into the app's metric vocabulary. Antigravity exposes
/// many fine-grained models that share a handful of quota pools, so models collapse into three meters —
/// "Gemini Pro", "Gemini Flash", and "Claude" (every non-Gemini model, incl. GPT-OSS) — each keeping the
/// worst (lowest) remaining fraction in its pool.
enum AntigravityUsageMapper {
    /// Quotas reset on a rolling 5-hour window.
    static let quotaPeriodMs = 5 * 60 * 60 * 1000

    /// Internal/duplicate model IDs that should never surface as a meter. Matched against the model ID
    /// (LS `modelOrAlias.model`, Cloud Code `model`/key); the Cloud Code path also drops `isInternal`.
    static let modelBlacklist: Set<String> = [
        "MODEL_CHAT_20706", "MODEL_CHAT_23310",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH", "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE", "MODEL_GOOGLE_GEMINI_2_5_PRO",
        "MODEL_PLACEHOLDER_M19", "MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M12"
    ]

    // MARK: - Response parsing

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

    // MARK: - Line building

    /// Collapse model configs into the three quota-pool meters, keeping the worst fraction per pool and
    /// ordering Gemini Pro → Gemini Flash → Claude. Blacklisted and empty-label models are dropped.
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
            .map { line(pool: $0.key, fraction: $0.value.fraction, resetTime: $0.value.resetTime) }
    }

    static func line(pool: String, fraction: Double, resetTime: Date?) -> MetricLine {
        let clamped = max(0, min(1, fraction))
        let used = (1 - clamped) * 100
        return .progress(
            label: pool,
            used: used.rounded(),
            limit: 100,
            format: .percent,
            resetsAt: resetTime,
            periodDurationMs: quotaPeriodMs
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
        let lower = normalizedLabel.lowercased()
        // Any Gemini model maps to a Gemini pool — Flash variants to "Gemini Flash", everything else
        // (Pro, Ultra, bare names) to "Gemini Pro" — so a Gemini model never leaks into the Claude pool.
        if lower.contains("gemini") {
            return lower.contains("flash") ? "Gemini Flash" : "Gemini Pro"
        }
        // Claude, GPT-OSS, and any other non-Gemini model share one pool.
        return "Claude"
    }

    static func sortKey(_ poolLabel: String) -> String {
        let lower = poolLabel.lowercased()
        if lower.contains("gemini"), lower.contains("pro") { return "0a_\(poolLabel)" }
        if lower.contains("gemini") { return "0b_\(poolLabel)" }
        if lower.contains("claude"), lower.contains("opus") { return "1a_\(poolLabel)" }
        if lower.contains("claude") { return "1b_\(poolLabel)" }
        return "2_\(poolLabel)"
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

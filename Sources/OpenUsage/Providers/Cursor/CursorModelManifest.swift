import Foundation

/// Bundled model-pricing manifest used to impute Cursor spend from the usage CSV.
/// Ported from `../cursorcat/Sources/CursorCat/Support/ModelManifest.swift`; the only
/// behavioral change is loading via `Bundle.module` instead of cursorcat's `AppBundle`.
struct CursorModelManifest: Decodable, Sendable {
    let retrievedAt: String
    let pricing: [String: CursorModelManifestPricingEntry]
    let aliasRules: [CursorModelManifestAliasRule]

    enum CodingKeys: String, CodingKey {
        case retrievedAt = "retrieved_at"
        case pricing
        case aliasRules = "alias_rules"
    }

    static let empty = CursorModelManifest(retrievedAt: "", pricing: [:], aliasRules: [])
}

/// Only the fields the spend imputation and the per-model leaderboard actually use are decoded.
/// `JSONDecoder` ignores the manifest's other keys (display name, provider id, max-mode uplift,
/// long-context multipliers) — the cost model deliberately bills at the base model rate and cannot
/// apply max-mode or long-context adjustments from row totals (see `CursorPricing.estimatedCostDollars`).
/// `family_id` groups pricing variants (e.g. `gpt-5.5` and `gpt-5.5-fast`) under one family so the
/// model leaderboard collapses them into a single "GPT-5.5" row (see `CursorPricing.family`).
struct CursorModelManifestPricingEntry: Decodable, Sendable {
    let familyID: String
    let familyDisplayName: String
    let inputPerMillion: Double
    let cacheWritePerMillion: Double
    let cacheReadPerMillion: Double
    let outputPerMillion: Double

    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case familyDisplayName = "family_display_name"
        case inputPerMillion = "input_per_million"
        case cacheWritePerMillion = "cache_write_per_million"
        case cacheReadPerMillion = "cache_read_per_million"
        case outputPerMillion = "output_per_million"
    }
}

struct CursorModelManifestAliasRule: Decodable, Sendable {
    let pattern: String
    let canonical: String
}

protocol CursorModelManifestSource: Sendable {
    func loadManifest() throws -> CursorModelManifest
}

struct CursorBundledModelManifestSource: CursorModelManifestSource {
    func loadManifest() throws -> CursorModelManifest {
        // `.copy("Resources/model_manifest.json")` lands the file at the bundle root, so look there
        // first; the "Resources" subdirectory lookup is a defensive fallback if SwiftPM nests it.
        let url = Bundle.openUsageResources.url(forResource: "model_manifest", withExtension: "json")
            ?? Bundle.openUsageResources.url(forResource: "model_manifest", withExtension: "json", subdirectory: "Resources")
        guard let url else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CursorModelManifest.self, from: data)
    }
}

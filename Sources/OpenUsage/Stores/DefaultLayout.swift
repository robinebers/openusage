import Foundation

/// Metrics enabled on first launch. Core quota meters and trends stay visible above the fold, while
/// balances, reset details, and spend-history rows are enabled but tucked behind each provider's caret.
/// `LayoutStore` filters this to whatever the active registry actually knows, so registries that don't
/// define an ID (e.g. the test fixtures) silently ignore it. The provider-section order isn't seeded
/// here: an empty saved order reconciles to plain registry order in `LayoutStore`.
enum DefaultLayout {
    static let metricIDs: [String] = [
        "claude.session", "claude.weekly", "claude.trend",
        "claude.extra", "claude.today", "claude.yesterday", "claude.last30",

        "codex.session", "codex.weekly", "codex.trend",
        "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30",

        "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend",
        "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30",

        "devin.daily", "devin.weekly", "devin.extra",

        "grok.creditsUsed", "grok.trend",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30"
    ]

    /// Frozen snapshot of the default-on metrics from the release that introduced default seeding.
    /// Existing users without a seeded-defaults key are treated as if these were already offered, so
    /// past opt-outs stay off while future additions to `metricIDs` can appear automatically once.
    static let migrationBaselineMetricIDs: [String] = [
        "claude.session", "claude.weekly", "claude.trend",
        "claude.extra", "claude.today", "claude.yesterday", "claude.last30",

        "codex.session", "codex.weekly", "codex.trend",
        "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30",

        "devin.daily", "devin.weekly", "devin.extra",

        "grok.creditsUsed", "grok.trend",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",

        "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend",
        "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30"
    ]

    /// Metrics pinned to the menu bar on first launch, so the app shows real numbers out of the box
    /// instead of a lone icon. Two per provider for Claude, Codex, and Cursor — the per-provider cap
    /// (`LayoutStore.maxPinsPerProvider`). Filtered to the active
    /// registry by `LayoutStore`, like `metricIDs`.
    static let pinnedMetricIDs: [String] = [
        "claude.session", "claude.weekly",
        "codex.session", "codex.weekly",
        "cursor.auto", "cursor.api"
    ]

    /// Metrics tucked below the per-provider "Shown on expand" divider on a fresh install. This is
    /// membership, not enablement: optional disabled rows like Sonnet or Cursor Requests/Credits are
    /// listed here so if the user enables them later they appear below the caret by default.
    /// Filtered to the active registry by `LayoutStore`, and only seeded on a genuinely fresh launch
    /// (existing layouts keep everything always-shown unless they reset customization).
    static let expandedMetricIDs: [String] = [
        "claude.sonnet", "claude.extra", "claude.today", "claude.yesterday", "claude.last30",
        "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30",
        "cursor.onDemand", "cursor.requests", "cursor.credits",
        "cursor.today", "cursor.yesterday", "cursor.last30",
        "devin.extra",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30"
    ]
}

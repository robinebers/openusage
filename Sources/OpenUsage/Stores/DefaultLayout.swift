import Foundation

/// Metrics enabled on first launch — one or two sensible ones per provider so every provider
/// section shows real rows out of the box. `LayoutStore` filters this to whatever the active
/// registry actually knows, so registries that don't define an ID (e.g. the test fixtures)
/// silently ignore it. The provider-section order isn't seeded here: an empty saved order
/// reconciles to plain registry order in `LayoutStore`.
enum DefaultLayout {
    static let metricIDs: [String] = [
        "claude.session", "claude.weekly", "claude.trend",
        "codex.session", "codex.weekly", "codex.trend",
        "devin.weekly", "devin.daily",
        "grok.creditsUsed",
        "cursor.usage", "cursor.auto", "cursor.api"
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
}

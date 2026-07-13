import Foundation

/// Latest normalized output for one provider refresh.
struct ProviderSnapshot: Hashable, Sendable, Codable {
    let providerID: String
    let displayName: String
    var plan: String?
    var lines: [MetricLine]
    var refreshedAt: Date
    /// Raw normalized daily history used to build spend rows. This always belongs to this Mac; peer
    /// history is combined only in the in-memory rendered view and is never written into the cache.
    var usageHistory: ProviderUsageHistory?
    /// A soft, non-blocking notice carried on a *successful* snapshot — e.g. Claude's "Re-login for live
    /// usage" when the saved login lacks the `user:profile` scope. Distinct from `errorCategory` (which is
    /// only on error snapshots): the refresh succeeded and partial data (spend tiles) still loads, so this
    /// surfaces as the provider header's amber triangle rather than blanking the provider. Cached with the
    /// snapshot; cleared on the next refresh when the condition resolves.
    var warning: String?
    /// Set only on error snapshots: a stable, non-PII bucket for the failure, read by telemetry on the
    /// failure path. Always `nil` on success (and error snapshots aren't cached), so it never persists.
    var errorCategory: ErrorCategory?

    init(
        providerID: String,
        displayName: String,
        plan: String? = nil,
        lines: [MetricLine],
        refreshedAt: Date = Date(),
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil,
        errorCategory: ErrorCategory? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.plan = plan
        self.lines = lines
        self.refreshedAt = refreshedAt
        self.usageHistory = usageHistory
        self.warning = warning
        self.errorCategory = errorCategory
    }

    func line(label: String) -> MetricLine? {
        lines.first { $0.label == label }
    }

    /// The success-path counterpart to `error(provider:message:)`: derives `providerID`/`displayName`
    /// from the provider so every runtime builds its snapshot the same way (`refreshedAt` is required
    /// so each call passes its own `now()`).
    static func make(
        provider: Provider,
        plan: String?,
        lines: [MetricLine],
        refreshedAt: Date,
        usageHistory: ProviderUsageHistory? = nil,
        warning: String? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: usageHistory,
            warning: warning
        )
    }

    /// Build an error snapshot straight from a caught error: the badge text stays the error's
    /// user-facing `localizedDescription` (UI copy is unchanged), and the telemetry category is derived
    /// from the error's `CategorizedError` conformance (falling back to `.other` for anything that
    /// doesn't classify itself). Preferred over `error(provider:message:)` wherever an `Error` is in hand.
    static func error(provider: Provider, error: Error) -> ProviderSnapshot {
        Self.error(
            provider: provider,
            message: error.localizedDescription,
            category: (error as? CategorizedError)?.errorCategory ?? .other
        )
    }

    static func error(provider: Provider, message: String, category: ErrorCategory? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.badge(label: MetricLine.errorBadgeLabel, text: message, colorHex: "#EF4444")],
            errorCategory: category
        )
    }
}

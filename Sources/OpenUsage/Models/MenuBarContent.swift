import Foundation

/// Resolved, ordered, capped data for the menu-bar strip, built from the pinned metrics and their live
/// values: one segment per pinned provider, each with its 1–2 pinned metrics. `isEmpty` means render
/// the plain app icon.
struct MenuBarContent: Equatable {
    /// One resolved pinned metric.
    struct Metric: Equatable {
        let id: String          // descriptor id
        let label: String       // metric label, e.g. "Session", read by VoiceOver
        let value: String       // tray display: a "%" for bounded metrics, the raw value (e.g. "$5.23") for unbounded
    }

    /// A provider and its pinned metrics, in order. One segment of the Text strip.
    struct Group: Equatable {
        let provider: Provider
        let metrics: [Metric]
        /// The account's tag on the provider mark ("A1"), set only when the strip shows more than one
        /// account of the same provider, so the marks can be told apart.
        var badge: String? = nil
    }

    /// Provider groups, in Accounts order. Dynamic: only metrics that currently
    /// have real data appear, and a provider whose pinned metrics all lack data drops out entirely
    /// (no orphan icon) — so the strip never renders "—" placeholders.
    let groups: [Group]
    /// An account's numbers are past their refresh slot (`WidgetDataStore.hasStaleAccount`).
    var isStale = false

    /// Nothing is pinned, or no pinned metric has data yet — the menu bar falls back to the app icon.
    var isEmpty: Bool { groups.isEmpty }

    /// VoiceOver summary for the rendered strip image, e.g.
    /// "Claude Session 41%, Weekly 12%; Cursor Credits $12", ending ", waiting for a provider" while stale.
    var accessibilityText: String {
        let summary = groups.map { group in
            let metrics = group.metrics.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
            return "\(group.provider.fullName) \(metrics)"
        }
        .joined(separator: "; ")
        return isStale ? summary + ", waiting for a provider" : summary
    }
}

@MainActor
enum MenuBarContentBuilder {
    /// Resolve pinned provider groups into menu-bar content. `groups` is `LayoutStore.pinnedGroups`
    /// (already ordered); `data` resolves each descriptor to its live `WidgetData` (i.e.
    /// `WidgetDataStore.data(for:)`), so the values follow the global meter style just like the
    /// dashboard rows.
    ///
    /// The strip is dynamic: a pinned metric without data is dropped (one of two pins renders alone at
    /// full size), and a provider with no data-carrying pins contributes no icon at all. Pins are
    /// membership; the strip shows whatever subset is real right now.
    static func build(groups: [ProviderMetrics], isStale: Bool = false, data: (WidgetDescriptor) -> WidgetData) -> MenuBarContent {
        let resolvedGroups = groups.compactMap { group -> MenuBarContent.Group? in
            let metrics = group.metrics.compactMap { descriptor -> MenuBarContent.Metric? in
                let data = data(descriptor)
                guard data.hasData else { return nil }
                return MenuBarContent.Metric(id: descriptor.id, label: trayLabel(descriptor.metricLabel), value: data.menuBarValue)
            }
            guard !metrics.isEmpty else { return nil }
            return MenuBarContent.Group(provider: group.provider, metrics: metrics)
        }
        return MenuBarContent(groups: badged(resolvedGroups), isStale: isStale)
    }

    /// Tags each group whose provider has more than one account in the strip.
    private static func badged(_ groups: [MenuBarContent.Group]) -> [MenuBarContent.Group] {
        let families = Dictionary(grouping: groups.indices) { groups[$0].provider.kind }
        var result = groups
        for index in families.values.filter({ $0.count > 1 }).joined() {
            result[index].badge = AccountInitials.tag(for: groups[index].provider.accountName)
        }
        return result
    }

    /// The metric's name for VoiceOver: Today reads "T"; every other label passes through.
    private static func trayLabel(_ metricLabel: String) -> String {
        metricLabel.lowercased() == "today" ? "T" : metricLabel
    }
}

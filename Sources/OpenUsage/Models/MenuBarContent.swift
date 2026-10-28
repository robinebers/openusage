import Foundation

/// Resolved, ordered, capped data for the menu-bar strip, built from the pinned metrics and their live
/// values: one segment per pinned provider, each with its 1–2 pinned metrics. `isEmpty` means render
/// the plain app icon.
struct MenuBarContent: Equatable {
    /// One resolved pinned metric.
    struct Metric: Equatable {
        let id: String          // descriptor id
        let label: String       // metric label, e.g. "Session" (shown when a provider has two metrics)
        let value: String       // tray display: a "%" for bounded metrics, the raw value (e.g. "$5.23") for unbounded, or the no-data marker
        let hasData: Bool
    }

    /// A provider and its pinned metrics, in order. One segment of the Text strip.
    struct Group: Equatable {
        let providerID: String
        let displayName: String
        let icon: String
        let metrics: [Metric]
        /// The account's tag on the provider mark ("A1"), set only when the strip shows more than one
        /// account of the same provider, so the marks can be told apart.
        var badge: String? = nil
    }

    /// Provider groups, in Accounts order. Dynamic: only metrics that currently
    /// have real data appear, and a provider whose pinned metrics all lack data drops out entirely
    /// (no orphan icon) — so the strip never renders "—" placeholders.
    let groups: [Group]

    /// Nothing is pinned, or no pinned metric has data yet — the menu bar falls back to the app icon.
    var isEmpty: Bool { groups.isEmpty }

    /// VoiceOver summary for the rendered strip image, e.g.
    /// "Claude Session 41%, Weekly 12%; Cursor Credits $12".
    var accessibilityText: String {
        groups.map { group in
            let metrics = group.metrics.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
            return "\(group.displayName) \(metrics)"
        }
        .joined(separator: "; ")
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
    static func build(groups: [ProviderMetrics], data: (WidgetDescriptor) -> WidgetData) -> MenuBarContent {
        let resolvedGroups = groups.compactMap { group -> MenuBarContent.Group? in
            let metrics = group.metrics.map { resolve($0, data($0)) }.filter(\.hasData)
            guard !metrics.isEmpty else { return nil }
            return MenuBarContent.Group(
                providerID: group.provider.id,
                displayName: group.provider.fullName,
                icon: group.provider.icon,
                metrics: metrics
            )
        }
        let providers = Dictionary(uniqueKeysWithValues: groups.map { ($0.provider.id, $0.provider) })
        let badgedGroups = badged(resolvedGroups, providers: providers)
return MenuBarContent(groups: badgedGroups)
    }

    /// Tags each group whose provider has more than one account in the strip.
    private static func badged(_ groups: [MenuBarContent.Group], providers: [String: Provider]) -> [MenuBarContent.Group] {
        let families = Dictionary(grouping: groups.indices) { providers[groups[$0].providerID]?.kind }
        var result = groups
        for index in families.values.filter({ $0.count > 1 }).joined() {
            result[index].badge = AccountInitials.tag(for: providers[groups[index].providerID]?.accountName ?? "")
        }
        return result
    }

    private static func resolve(_ descriptor: WidgetDescriptor, _ data: WidgetData) -> MenuBarContent.Metric {
        MenuBarContent.Metric(
            id: descriptor.id,
            label: trayLabel(descriptor.metricLabel),
            value: data.menuBarValue,
            hasData: data.hasData
        )
    }

    /// Tray-only label shortening (the dashboard keeps the full names): the long time-window metrics
    /// collapse to a single letter so a two-metric stack stays narrow. Unknown labels pass through.
    private static func trayLabel(_ metricLabel: String) -> String {
        switch metricLabel.lowercased() {
        case "today": return "T"
        case "yesterday": return "Y"
        case "last 30 days": return "M"
        default: return metricLabel
        }
    }
}

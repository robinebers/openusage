import Foundation

/// Resolved, ordered, capped data for the menu-bar strip, built from the pinned metrics and their live
/// values. The renderers consume this: `groups` drives the Text style (one segment per pinned provider,
/// each with its 1–2 pinned metrics), `bars` drives the Bars style (the first four bounded metrics — any
/// with a fill, not just percentages — in order). `isEmpty` means render the plain app icon.
struct MenuBarContent: Equatable {
    /// One resolved pinned metric.
    struct Metric: Equatable {
        let id: String          // descriptor id
        let label: String       // metric label, e.g. "Session" (shown when a provider has two metrics)
        let value: String       // tray display: a "%" for bounded metrics, the raw value (e.g. "$5.23") for unbounded, or the no-data marker
        let fraction: Double     // 0...1 fill, meaningful for bounded metrics (drives the bars)
        let isBounded: Bool      // has a limit → has a fill, so it can render as a bar
        let hasData: Bool
        /// Resolved account-card title. Used only when several account values share one visual stack,
        /// so VoiceOver can name which value belongs to which account.
        let accountDisplayName: String?

        init(
            id: String,
            label: String,
            value: String,
            fraction: Double,
            isBounded: Bool,
            hasData: Bool,
            accountDisplayName: String? = nil
        ) {
            self.id = id
            self.label = label
            self.value = value
            self.fraction = fraction
            self.isBounded = isBounded
            self.hasData = hasData
            self.accountDisplayName = accountDisplayName
        }
    }

    /// A provider and its pinned metrics, in order. One segment of the Text strip.
    struct Group: Equatable {
        let providerID: String
        let displayName: String
        let icon: IconSource
        let metrics: [Metric]
    }

    /// Provider groups for the Text style, in Customize order. Dynamic: only metrics that currently
    /// have real data appear, and a provider whose pinned metrics all lack data drops out entirely
    /// (no orphan icon) — so the strip never renders "—" placeholders.
    let groups: [Group]
    /// Bounded metrics (those with a fill) for the Bars style, flattened in order and capped to four.
    let bars: [Metric]

    /// Nothing is pinned, every pinned provider is disabled, or no pinned metric has data yet — the
    /// menu bar falls back to the app icon.
    var isEmpty: Bool { groups.isEmpty }

    /// VoiceOver summary for the rendered strip image, e.g.
    /// "Claude Session 41%, Weekly 12%; Cursor Credits $12".
    var accessibilityText: String {
        groups.map { group in
            let accountNames = Set(group.metrics.compactMap(\.accountDisplayName))
            if accountNames.count > 1 {
                let metrics = group.metrics.map { metric in
                    "\(metric.accountDisplayName ?? group.displayName) \(metric.label) \(metric.value)"
                }
                .joined(separator: ", ")
                return "\(group.displayName) accounts: \(metrics)"
            }
            let metrics = group.metrics.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
            return "\(group.displayName) \(metrics)"
        }
        .joined(separator: "; ")
    }
}

@MainActor
enum MenuBarContentBuilder {
    /// Max bars the compact style renders (matches the original OpenUsage tray).
    static let maxBars = 4

    /// Resolve pinned provider groups into menu-bar content. `groups` is `LayoutStore.pinnedGroups`
    /// (already ordered, disabled providers excluded); `data` resolves each descriptor to its live
    /// `WidgetData` (i.e. `WidgetDataStore.data(for:)`), so the values follow the global meter style
    /// just like the dashboard tiles.
    ///
    /// The strip is dynamic: a pinned metric without data is dropped (one of two pins renders alone at
    /// full size), and a provider with no data-carrying pins contributes no icon at all. Pins are
    /// membership; the strip shows whatever subset is real right now.
    /// `title` resolves each provider's card title (the VoiceOver summary is a human-facing name, so
    /// the caller passes the account-registry resolver); defaults to the baked derived name.
    static func build(
        groups: [ProviderMetrics],
        data: (WidgetDescriptor) -> WidgetData,
        title: (Provider) -> String = { $0.displayName }
    ) -> MenuBarContent {
        let resolvedGroups = groups.compactMap { group -> MenuBarContent.Group? in
            let displayName = title(group.provider)
            let metrics = group.metrics.map {
                resolve($0, data($0), accountDisplayName: displayName)
            }
            .filter(\.hasData)
            guard !metrics.isEmpty else { return nil }
            return MenuBarContent.Group(
                providerID: group.provider.id,
                displayName: displayName,
                icon: group.provider.icon,
                metrics: metrics
            )
        }
        let textGroups = coalescingSingleMetricAccountGroups(resolvedGroups)
        // Bars show any *bounded* metric (it has a fill), not just percentages. Unbounded values (raw
        // spend/credits, no limit) have no fill and are dropped.
        let bars = textGroups
            .flatMap(\.metrics)
            .filter(\.isBounded)
            .prefix(maxBars)
        return MenuBarContent(groups: textGroups, bars: Array(bars))
    }

    private static func resolve(
        _ descriptor: WidgetDescriptor,
        _ data: WidgetData,
        accountDisplayName: String
    ) -> MenuBarContent.Metric {
        MenuBarContent.Metric(
            id: descriptor.id,
            label: trayLabel(descriptor.metricLabel),
            value: data.menuBarValue,
            fraction: data.fraction,
            isBounded: data.isBounded,
            hasData: data.hasData,
            accountDisplayName: accountDisplayName
        )
    }

    /// When several account cards of one provider each expose a single pinned metric, render their
    /// values as one two-line provider segment instead of repeating the provider icon. The metrics
    /// need not be the same kind — an account starring Weekly stacks with one starring Session, read
    /// positionally in card order. Match order is input order, which is the live drag-and-drop card
    /// order from `LayoutStore.pinnedGroups`.
    private static func coalescingSingleMetricAccountGroups(
        _ groups: [MenuBarContent.Group]
    ) -> [MenuBarContent.Group] {
        var consumed = Set<Int>()
        var result: [MenuBarContent.Group] = []

        for (index, group) in groups.enumerated() where !consumed.contains(index) {
            guard group.metrics.count == 1 else {
                result.append(group)
                continue
            }
            let family = ProviderAccountID.family(of: group.providerID)
            let matches = groups.indices.filter { candidateIndex in
                guard !consumed.contains(candidateIndex) else { return false }
                let candidate = groups[candidateIndex]
                return ProviderAccountID.family(of: candidate.providerID) == family
                    && candidate.metrics.count == 1
            }
            guard matches.count > 1,
                  matches.contains(where: { ProviderAccountID.isAccountCard(groups[$0].providerID) })
            else {
                result.append(group)
                continue
            }

            consumed.formUnion(matches)
            result.append(MenuBarContent.Group(
                providerID: group.providerID,
                displayName: family.capitalized,
                icon: group.icon,
                metrics: matches.map { groups[$0].metrics[0] }
            ))
        }
        return result
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

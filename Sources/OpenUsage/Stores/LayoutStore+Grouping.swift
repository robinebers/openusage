extension LayoutStore {
    func provider(id: String) -> Provider? { registry.provider(id: id) }

    func descriptor(for widget: PlacedWidget) -> WidgetDescriptor? {
        registry.descriptor(id: widget.descriptorID)
    }

    private func providerID(of widget: PlacedWidget) -> String? {
        registry.descriptor(id: widget.descriptorID)?.providerID
    }

    var visiblePlaced: [PlacedWidget] {
        placed.filter { widget in
            guard let providerID = providerID(of: widget) else { return true }
            return isProviderEnabled(providerID)
        }
    }

    var availableToAdd: [WidgetDescriptor] {
        let placedIDs = Set(placed.map(\.descriptorID))
        return registry.descriptors.filter { !placedIDs.contains($0.id) && isProviderEnabled($0.providerID) }
    }

    func isMetricEnabled(_ descriptorID: String) -> Bool {
        placed.contains { $0.descriptorID == descriptorID }
    }

    /// Whether any enabled provider ships the spend-history tiles — the capability gate for the
    /// Total Spend card. Keyed off the registry's descriptors, not off refreshed data, so the card
    /// can show its "No spend data" state on a fresh morning instead of vanishing.
    var hasSpendCapableProvider: Bool {
        !spendCapableProviders.isEmpty
    }

    /// Enabled providers that ship the spend-history tiles (`WidgetDescriptor.spendTiles`), in the
    /// user's provider order — the exact set the Total Spend card aggregates. Deliberately *not*
    /// `displayGroups`: a provider whose every metric is hidden in Customize still spends money and
    /// must still count, and look-alike dollar rows from other providers (OpenRouter's API-spend
    /// "Today") must not.
    var spendCapableProviders: [Provider] {
        let capableIDs = Set(registry.descriptors.filter(\.isSpendTile).map(\.providerID))
        return orderedProviders().filter { capableIDs.contains($0.id) && isProviderEnabled($0.id) }
    }

    // MARK: - Provider grouping

    func orderedProviders() -> [Provider] {
        providerOrder.compactMap { registry.provider(id: $0) }
    }

    /// Enabled (and provider-enabled) widgets grouped by provider, in the user's provider order, each
    /// provider's metrics kept in the provider's custom metric order. Drives the grouped dashboard list; providers with
    /// no visible metric are dropped so the dashboard only shows groups that have something to show.
    var displayGroups: [ProviderGroup] {
        orderedProviders().compactMap { provider in
            let widgetsByDescriptor = Dictionary(
                visiblePlaced
                    .filter { providerID(of: $0) == provider.id }
                    .map { ($0.descriptorID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let widgets = metricOrder(for: provider.id).compactMap { widgetsByDescriptor[$0] }
            guard !widgets.isEmpty else { return nil }
            let alwaysShown = widgets.filter { !expandedMetricIDs.contains($0.descriptorID) }
            let expanded = widgets.filter { expandedMetricIDs.contains($0.descriptorID) }
            // A provider whose only enabled metrics are all marked expanded would otherwise render an
            // empty card with a caret — promote them to always-shown so the card always has rows.
            if alwaysShown.isEmpty {
                return ProviderGroup(provider: provider, alwaysShownWidgets: expanded, expandedWidgets: [])
            }
            return ProviderGroup(provider: provider, alwaysShownWidgets: alwaysShown, expandedWidgets: expanded)
        }
    }

    /// Every enabled provider with *all* the metrics it supports, in its saved metric order. Enabled and
    /// disabled rows stay in-place; the switch only controls visibility.
    var customizeGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            guard isProviderEnabled(provider.id) else { return nil }
            let metrics = orderedSupportedMetrics(for: provider.id)
            guard !metrics.isEmpty else { return nil }
            return ProviderMetrics(
                provider: provider,
                alwaysShownMetrics: metrics.filter { !expandedMetricIDs.contains($0.id) },
                expandedMetrics: metrics.filter { expandedMetricIDs.contains($0.id) }
            )
        }
    }

    /// The L1 Customize list: every known provider in the user's saved order, regardless of enablement.
    /// Disabled providers appear here (greyed in the UI) so the user can re-enable them or open their
    /// detail — unlike `customizeGroups`, which filters them out for the dashboard and the old flat
    /// Customize. Each row carries the enablement flag, the total metric count (the badge number), and
    /// the pinned count.
    var customizeProviderRows: [ProviderRow] {
        orderedProviders().map { provider in
            ProviderRow(
                provider: provider,
                isEnabled: isProviderEnabled(provider.id),
                metricCount: metricCount(for: provider.id),
                pinnedCount: pinnedCount(forProvider: provider.id)
            )
        }
    }

    /// Total metrics a provider supports — the L1 row's badge number. Registry descriptor count,
    /// independent of how many the user has enabled.
    func metricCount(for providerID: String) -> Int {
        registry.descriptors(for: providerID).count
    }

    /// The L2 Customize detail for one provider: every metric it supports, split across the
    /// "Always Visible" / "On Demand" divider, in its saved metric order. Available even when the
    /// provider is disabled so L2 can render dimmed-but-editable. nil for an unknown provider or one
    /// with no metrics — the per-provider slice of `customizeGroups` without the enablement guard.
    func customizeDetail(for providerID: String) -> ProviderMetrics? {
        guard let provider = registry.provider(id: providerID) else { return nil }
        let metrics = orderedSupportedMetrics(for: providerID)
        guard !metrics.isEmpty else { return nil }
        return ProviderMetrics(
            provider: provider,
            alwaysShownMetrics: metrics.filter { !expandedMetricIDs.contains($0.id) },
            expandedMetrics: metrics.filter { expandedMetricIDs.contains($0.id) }
        )
    }

    /// A provider's supported metrics in custom order, independent of whether each metric is enabled.
    func orderedSupportedMetrics(for providerID: String) -> [WidgetDescriptor] {
        metricOrder(for: providerID).compactMap { registry.descriptor(id: $0) }
    }

    func metricOrderWithDivider(for providerID: String, dividerID: String) -> [String] {
        let ordered = orderedSupportedMetrics(for: providerID).map(\.id)
        return ordered.filter { !expandedMetricIDs.contains($0) }
            + [dividerID]
            + ordered.filter { expandedMetricIDs.contains($0) }
    }

    func isProviderExpanded(_ providerID: String) -> Bool {
        expandedProviderIDs.contains(providerID)
    }

}

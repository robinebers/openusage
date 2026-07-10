extension LayoutStore {
    // MARK: - Menu bar pins

    /// Per-provider cap is a rendering constraint — the Text strip stacks a provider's values two to a
    /// column, so a third would not fit the menu bar height.
    static let maxPinsPerProvider = 2

    func isPinned(_ descriptorID: String) -> Bool { pinnedMetricIDs.contains(descriptorID) }

    func togglePin(_ descriptorID: String) {
        setPinned(!isPinned(descriptorID), for: descriptorID)
    }

    var pinnedCount: Int { pinnedMetricIDs.count }

    func pinnedCount(forProvider providerID: String) -> Int {
        pinnedMetricIDs.count { registry.descriptor(id: $0)?.providerID == providerID }
    }

    /// Whether `descriptorID` can be newly pinned without breaking a cap. Already-pinned ids return
    /// `true`, so the toggle stays active for unpinning.
    func canPin(_ descriptorID: String) -> Bool {
        if pinnedMetricIDs.contains(descriptorID) { return true }
        guard let descriptor = registry.descriptor(id: descriptorID), descriptor.pinnable else { return false }
        if pinnedCount(forProvider: descriptor.providerID) >= Self.maxPinsPerProvider { return false }
        return true
    }

    /// Why `descriptorID` can't be pinned right now, or `nil` when it can. The single source for the
    /// pin button's tooltip and the denied-click feedback, so both always state the same rule.
    func pinDenialReason(_ descriptorID: String) -> String? {
        guard !canPin(descriptorID) else { return nil }
        if let providerID = registry.descriptor(id: descriptorID)?.providerID,
           pinnedCount(forProvider: providerID) >= Self.maxPinsPerProvider {
            return "Up to \(Self.maxPinsPerProvider) stars per provider"
        }
        return nil
    }

    /// Record a denied pin attempt so the footer can explain the cap (shown for a few seconds,
    /// with a deny shake on every attempt).
    func notePinDenied(_ descriptorID: String) {
        guard let reason = pinDenialReason(descriptorID) else { return }
        pinNotice.present(reason)
    }

    /// Pinned metrics grouped by provider, in the user's Customize order (provider order, then each
    /// provider's metric order). A temporarily disabled provider is excluded from the rendered groups
    /// but keeps its pins. Drives the menu-bar strip.
    var pinnedGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            guard isProviderEnabled(provider.id) else { return nil }
            // Keep the strip order matching Customize: always-shown pins first, then expanded ones.
            let metrics = orderedSupportedMetrics(for: provider.id).filter { pinnedMetricIDs.contains($0.id) }
            return metrics.isEmpty ? nil : ProviderMetrics(
                provider: provider,
                alwaysShownMetrics: metrics.filter { !expandedMetricIDs.contains($0.id) },
                expandedMetrics: metrics.filter { expandedMetricIDs.contains($0.id) }
            )
        }
    }
}

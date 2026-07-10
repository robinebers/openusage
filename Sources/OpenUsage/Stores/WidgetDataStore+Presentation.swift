import Foundation

extension WidgetDataStore {
    /// The provider's latest refresh error, or `nil` when its last refresh succeeded.
    func errorMessage(for providerID: String) -> String? {
        providerErrors[providerID]
    }

    /// A soft, non-blocking notice from the provider's latest *successful* snapshot (e.g. Claude's
    /// "Re-login for live usage" when the login lacks the `user:profile` scope). `nil` when there's no
    /// warning. After a *failed* refresh the store keeps the last good snapshot (so this warning can
    /// linger) while setting `providerErrors` — use `headerNotice(for:)` for the rendered triangle so a
    /// current hard error isn't masked by a stale soft warning.
    func warningMessage(for providerID: String) -> String? {
        snapshots[providerID]?.warning
    }

    /// The provider header's amber-triangle notice: a hard refresh error takes precedence over a stale
    /// soft warning from the last successful snapshot. After a failed refresh the store keeps the last
    /// good snapshot (so `warningMessage` still returns its warning) while `errorMessage` holds the
    /// current failure — the error must win, or a stale "Re-login for live usage" warning would hide a
    /// real "Token expired" failure. When there's no error, the soft warning (if any) shows.
    func headerNotice(for providerID: String) -> String? {
        errorMessage(for: providerID) ?? warningMessage(for: providerID)
    }

    func data(for descriptor: WidgetDescriptor) -> WidgetData {
        if PlanWidget.isPlan(descriptor) {
            var result = descriptor.sample
            if let plan = plan(for: descriptor.providerID) {
                result.valueTextOverride = plan
                result.hasData = true
            } else {
                result.hasData = false
            }
            return result
        }

        var result: WidgetData
        if let snapshot = snapshots[descriptor.providerID],
           let line = snapshot.line(label: descriptor.metricLabel),
           let data = resolve(line, descriptor: descriptor) {
            result = data
        } else {
            // No real metric line backs this placed tile, so the sample's numbers are placeholders.
            // Flag it as no-data; the tile renders "No data" instead of inventing usage.
            result = descriptor.sample
            result.hasData = false
        }

        // Single global choke point: tiles, the Add-Widget gallery, and the menu-bar value all funnel
        // through here, so stamping the mode once makes them follow the global setting. Inert for
        // unbounded tiles (limit == nil), whose displayed value ignores displayMode.
        result.displayMode = meterStyle
        result.resetDisplayMode = resetDisplayMode
        result.alwaysShowPacing = alwaysShowPacing
        result.widgetID = descriptor.id
        return result
    }

    /// The plan label for a provider's latest snapshot (also feeds the optional Plan widget). `nil` until a
    /// snapshot exists or when the provider doesn't expose a plan.
    func plan(for providerID: String) -> String? {
        snapshots[providerID]?.plan
    }

    /// How long a displayed snapshot may age before the header calls it out. A healthy provider's
    /// snapshot resets to ~0 on every successful pass and only brushes one interval just before the next
    /// one, so the threshold sits at two intervals: it fires only when a refresh has actually been missed
    /// — a refresh loop that keeps failing, or a long-suspended background timer — never on the normal
    /// per-cycle aging, which would flicker a hint on healthy providers.
    static let stalenessThreshold = RefreshSetting.interval * 2

    /// A compact "Outdated" hint for the provider's on-screen snapshot, surfaced only once that snapshot
    /// has aged past `stalenessThreshold`; `nil` while the data is still current (the common case), so the
    /// header stays clean until staleness is real. The label is short on purpose — a long plan name plus a
    /// full "Updated 3h ago" string would overflow the header — so the precise age rides in the tooltip.
    /// This is the visible counterpart to the silent fossilized-cache problem (#582): a failing-refresh
    /// loop keeps the last good plan/limits on screen, and without this nothing told the user that data was
    /// stale. Reads the store's injected clock, which tests pin to a fixed value.
    func stalenessHint(for providerID: String) -> StalenessHint? {
        guard let refreshedAt = snapshots[providerID]?.refreshedAt else { return nil }
        let age = now().timeIntervalSince(refreshedAt)
        guard age >= Self.stalenessThreshold, let duration = Formatters.compactDuration(age) else {
            return nil
        }
        return StalenessHint(label: "Outdated", tooltip: "Last updated \(duration) ago")
    }

}

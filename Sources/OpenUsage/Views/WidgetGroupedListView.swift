import SwiftUI

/// The dashboard display: one inset group per provider (System Settings style). A provider's icon + name
/// sits above a rounded container holding its metric rows, so heterogeneous metric sets read as belonging
/// to their provider. Rows are the shared `WidgetRowView`, fed by the same `WidgetDataStore` the menu bar
/// uses.
///
/// Reordering works here directly (no Customize needed): drag any metric row to reorder it within its
/// provider, or drag a provider's header line to reorder whole providers. Customize stays the discoverable,
/// obvious place to do the same plus toggle metrics on/off. Both surfaces use the same local gesture/geometry
/// helper so they work inside the menu-bar popover without a system drag/drop session.
struct WidgetGroupedListView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var activeProviderID: String?
    @State private var activeMetricID: String?
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        // Provider-section spacing is noticeably wider than the in-card row rhythm (so groups
        // still read as groups); the exact step comes from the density setting.
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            ForEach(layout.displayGroups) { group in
                section(group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(ReorderFramePreferenceKey.self) { rowFrames = $0 }
        .animation(Motion.spring, value: layout.displayGroups.map(\.provider.id))
    }

    private func section(_ group: ProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header(group)
            container(group)
        }
        .opacity(activeProviderID == group.provider.id ? 0 : 1)
        .reorderFrame(id: group.provider.id, in: .named(reorderSpaceName))
    }

    private func header(_ group: ProviderGroup) -> some View {
        ProviderSectionHeader(
            provider: group.provider,
            plan: dataStore.plan(for: group.provider.id),
            warning: dataStore.errorMessage(for: group.provider.id),
            refreshing: dataStore.refreshingProviderIDs.contains(group.provider.id),
            staleness: dataStore.stalenessHint(for: group.provider.id)
        )
        // 8pt here (+ 4pt internal) so the provider header uses the same inset as the Customize screen —
        // both land the provider name at the same offset from the popover edge.
        .padding(.horizontal, 8)
        .highPriorityGesture(providerDragGesture(for: group))
        .contextMenu {
            Button("Refresh \(group.provider.displayName)") {
                Task { await dataStore.refresh(providerID: group.provider.id, force: true) }
            }
            Button("Customize…") {
                withAnimation(Motion.modeSwitch) { layout.isEditing = true }
            }
        }
    }

    /// A row's placed widget paired with its resolved descriptor + data, so each `dataStore.data(for:)`
    /// is computed once per render and reused by both the condensing rule and the row. Keyed off the
    /// `PlacedWidget` so `ForEach` identity stays exactly what it was before this was precomputed.
    private struct ResolvedRow: Identifiable {
        let widget: PlacedWidget
        let descriptor: WidgetDescriptor
        let data: WidgetData
        var id: PlacedWidget.ID { widget.id }
    }

    private func container(_ group: ProviderGroup) -> some View {
        // Resolve each row's descriptor + data exactly once per render, then reuse it for both the
        // neighbor-aware condensing rule and the row itself — `dataStore.data(for:)` used to be
        // recomputed several times per row (twice per adjacent pair plus once in `row`).
        let rows = group.widgets.compactMap { widget -> ResolvedRow? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return ResolvedRow(widget: widget, descriptor: descriptor, data: dataStore.data(for: descriptor))
        }
        let condensedIDs = condensedTextRowIDs(rows)
        // Same card builder the lifted preview uses, so the floating chip can't drift from the live card.
        return DashboardMetricCard {
            ForEach(rows) { entry in
                row(entry.descriptor, data: entry.data, in: group.provider.id,
                    condensedTop: condensedIDs.contains(entry.descriptor.id))
            }
        }
    }

    /// Neighbor-aware rule: IDs of text-only rows sitting directly under another text-only row.
    /// Rows can't see their neighbors, so the list computes the pairs; Compact density pulls these
    /// rows up so a run of one-liners reads as one cluster.
    private func condensedTextRowIDs(_ rows: [ResolvedRow]) -> Set<String> {
        var ids = Set<String>()
        for (previous, current) in zip(rows, rows.dropFirst())
        where !previous.data.isBounded && !current.data.isBounded {
            ids.insert(current.descriptor.id)
        }
        return ids
    }

    private func row(_ descriptor: WidgetDescriptor, data: WidgetData, in providerID: String, condensedTop: Bool) -> some View {
        let isActive = activeMetricID == descriptor.id
        return WidgetRowView(
            data: data,
            onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() },
            onToggleMeterStyle: { dataStore.meterStyle.toggle() },
            condensedTop: condensedTop
        )
            .contentShape(Rectangle())
            .opacity(isActive ? 0 : 1)
            .highPriorityGesture(metricDragGesture(for: descriptor, providerID: providerID))
            .contextMenu { rowMenu(descriptor, providerID: providerID) }
            .reorderFrame(id: descriptor.id, in: .named(reorderSpaceName))
    }

    /// Desktop-native management for everything that is otherwise hover-or-hidden: pinning, hiding,
    /// the global reset-format flip, and a per-provider refresh — without a trip into Customize.
    @ViewBuilder
    private func rowMenu(_ descriptor: WidgetDescriptor, providerID: String) -> some View {
        if descriptor.pinnable {
            Button(layout.isPinned(descriptor.id) ? "Unpin" : "Pin to menu bar") {
                if layout.isPinned(descriptor.id) {
                    layout.setPinned(false, for: descriptor.id)
                } else if layout.canPin(descriptor.id) {
                    layout.setPinned(true, for: descriptor.id)
                } else {
                    layout.notePinDenied(descriptor.id)
                }
            }
        }
        Button("Hide") {
            layout.setMetricEnabled(descriptor.id, false)
        }
        if dataStore.data(for: descriptor).hasMeterStyleToggle {
            Button(dataStore.meterStyle == .remaining
                   ? "Show what's used"
                   : "Show what's left") {
                dataStore.meterStyle.toggle()
            }
        }
        if dataStore.data(for: descriptor).hasResetLabel {
            Button(dataStore.resetDisplayMode == .relative
                   ? "Show exact reset times"
                   : "Show reset countdowns") {
                dataStore.resetDisplayMode.toggle()
            }
        }
        Divider()
        if let provider = layout.provider(id: providerID) {
            Button("Refresh \(provider.displayName)") {
                Task { await dataStore.refresh(providerID: providerID, force: true) }
            }
        }
    }

    private func providerDragGesture(for group: ProviderGroup) -> some Gesture {
        reorderDragGesture(
            id: group.provider.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: group, value: $0) },
            orderedIDs: { layout.displayGroups.map(\.provider.id) },
            reorder: { layout.reorderProvider(dragged: group.provider.id, target: $0) }
        )
    }

    private func metricDragGesture(for descriptor: WidgetDescriptor, providerID: String) -> some Gesture {
        reorderDragGesture(
            id: descriptor.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { makeMetricLift(for: descriptor, value: $0) },
            orderedIDs: {
                layout.displayGroups
                    .first { $0.provider.id == providerID }?
                    .widgets
                    .compactMap { layout.descriptor(for: $0)?.id } ?? []
            },
            reorder: { layout.reorderMetric(dragged: descriptor.id, target: $0, in: providerID) }
        )
    }

    private func makeProviderLift(for group: ProviderGroup, value: DragGesture.Value) -> ReorderLift? {
        let rows = group.widgets.compactMap { widget -> WidgetData? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return dataStore.data(for: descriptor)
        }
        return ReorderLift.make(
            id: group.provider.id,
            payload: .dashboardProvider(
                provider: group.provider,
                plan: dataStore.plan(for: group.provider.id),
                rows: rows
            ),
            value: value,
            frames: rowFrames
        )
    }

    private func makeMetricLift(for descriptor: WidgetDescriptor, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: descriptor.id,
            payload: .dashboardMetric(data: dataStore.data(for: descriptor)),
            value: value,
            frames: rowFrames
        )
    }
}

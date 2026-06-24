import SwiftUI

/// The Customize screen. One block per enabled provider: a draggable header (reorders whole providers) over a
/// rounded card of metric rows, each a native `Toggle` with a drag grip (reorders metrics within that provider).
/// The provider is the group; each metric is a toggle inside it — so heterogeneous metric sets (Claude has many,
/// Grok has two) all read the same way.
///
/// Reordering uses `DragGesture` plus local row geometry. That keeps movement inside the menu-bar popover instead
/// of relying on SwiftUI's pasteboard-backed drag/drop session, which does not engage reliably here.
struct CustomizeView: View {
    @Environment(LayoutStore.self) private var layout
    @Binding var contentHeight: CGFloat
    @Binding var hasMeasuredContent: Bool
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var activeProviderID: String?
    @State private var activeMetricID: String?
    @State private var hoveredMetricID: String?
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private var isReordering: Bool { activeProviderID != nil || activeMetricID != nil }

    var body: some View {
        scrollContent
        .frame(maxWidth: .infinity)
    }

    /// Fills the region the dashboard's pinned footer leaves; reports its content height up so
    /// `DashboardView` can clamp the popover. A mid-drag measurement is ignored (`!isReordering`) so
    /// the lifted row's transient layout never reseeds the popover height.
    private var scrollContent: some View {
        MeasuredScrollScreen(onMeasure: { newValue in
            if newValue > 0, !isReordering {
                contentHeight = newValue
                hasMeasuredContent = true
            }
        }) {
            content
        }
        .onPreferenceChange(ReorderFramePreferenceKey.self) { rowFrames = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if layout.customizeGroups.isEmpty {
            VStack(spacing: 6) {
                Text("No providers connected")
                    .font(.callout)
                Text("Turn providers on in Settings → Providers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            // Same section rhythm as the dashboard list (both read the density setting).
            VStack(alignment: .leading, spacing: density.sectionSpacing) {
                ForEach(layout.customizeGroups) { group in
                    providerBlock(group)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .animation(Motion.spring, value: layout.customizeGroups.map(\.provider.id))
        }
    }

    private func providerBlock(_ group: ProviderMetrics) -> some View {
        // Same header→card gap as the dashboard section (`WidgetGroupedListView`).
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            providerHeader(group)
            metricCard(group)
        }
        .opacity(activeProviderID == group.provider.id ? 0 : 1)
        .reorderFrame(id: group.provider.id, in: .named(reorderSpaceName))
    }

    private func providerHeader(_ group: ProviderMetrics) -> some View {
        // The exact same header as the dashboard (`WidgetGroupedListView.header`): the leading
        // dot-grid drag handle marks the line as draggable, the provider mark sits trailing. Customize
        // just omits the plan, warning, and "Outdated" staleness tag — the only things that differ here.
        ProviderSectionHeader(provider: group.provider, showsDragHandle: true)
        // Align the header with the metric card's rows: rows are inset 12pt inside the card and the
        // header carries its own internal inset, so +8 lines the provider name up with the row grip —
        // the same inset on both edges.
        .padding(.horizontal, 8)
        .highPriorityGesture(providerDragGesture(for: group))
    }

    private func metricCard(_ group: ProviderMetrics) -> some View {
        return VStack(spacing: 0) {
            // One stable `ForEach` prevents SwiftUI from tearing down the active dragged row when it
            // crosses the divider. With separate always-shown/expanded loops the source view can be
            // removed mid-gesture, leaving the lift overlay stuck until another state change.
            ForEach(metricCardRows(for: group)) { row in
                switch row {
                case .metric(let metric):
                    metricRow(metric, in: group.provider.id)
                case .divider:
                    expandedDivider(providerID: group.provider.id)
                }
            }
        }
        .cardSurface()
    }

    private func metricCardRows(for group: ProviderMetrics) -> [CustomizeMetricCardRow] {
        group.alwaysShownMetrics.map(CustomizeMetricCardRow.metric)
            + [.divider]
            + group.expandedMetrics.map(CustomizeMetricCardRow.metric)
    }

    /// The single dashed boundary between always-shown rows and rows revealed by the dashboard caret.
    /// Kept visually simple so it reads as one drop target instead of several moving controls.
    private func expandedDivider(providerID: String) -> some View {
        let yOutset = max(0, (density.estimatedMetricRowHeight - density.customizeDividerRowHeight) / 2)
        return dashedRule
        .padding(.horizontal, 12)
        .frame(height: density.customizeDividerRowHeight)
        // The visible divider is compact, but its measured reorder frame remains row-sized. That keeps
        // the same threshold behavior as metric rows without making the Customize card look gappy.
        .reorderFrame(id: expandedDividerID(for: providerID), in: .named(reorderSpaceName), yOutset: yOutset)
        .accessibilityLabel("Shown on expand divider")
    }

    private var dashedRule: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 1)
            .overlay(
                Line()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.tertiary)
            )
    }

    private func metricRow(_ metric: WidgetDescriptor, in providerID: String) -> some View {
        let isActive = activeMetricID == metric.id
        // Same row builder the lifted preview uses, so the floating chip can't drift from the live row.
        return CustomizeMetricRow(
            title: metric.title,
            // Grip + label form the drag handle; the trailing pin + toggle stay normal tappable controls.
            handle: { handle in
                handle
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        metricDragGesture(
                            for: metric.id,
                            providerID: providerID,
                            title: metric.title
                        )
                    )
            },
            trailing: {
                pinButton(metric)
                Toggle("", isOn: Binding(
                    get: { layout.isMetricEnabled(metric.id) },
                    set: { layout.setMetricEnabled(metric.id, $0) }
                ))
                .settingsSwitchStyle()
            }
        )
        .contentShape(Rectangle())
        .opacity(isActive ? 0 : 1)
        .onHover { hovering in
            if hovering {
                hoveredMetricID = metric.id
            } else if hoveredMetricID == metric.id {
                hoveredMetricID = nil
            }
        }
        .reorderFrame(id: metric.id, in: .named(reorderSpaceName))
    }

    /// The pin-to-menu-bar control on a metric row: a filled pin when pinned (always shown), an outline
    /// pin on row hover otherwise. At a cap the pin dims but stays clickable — a denied click routes
    /// through `notePinDenied`, which surfaces the reason in the footer (WhatsApp-style feedback)
    /// instead of silently doing nothing.
    @ViewBuilder
    private func pinButton(_ metric: WidgetDescriptor) -> some View {
        // A non-pinnable widget (the Usage Trend chart) shows no pin affordance at all — the tray can't
        // render it, so offering a pin would only ever be denied.
        if metric.pinnable {
            let pinned = layout.isPinned(metric.id)
            let blocked = !layout.canPin(metric.id)   // false when pinned, so unpin always works
            let visible = pinned || hoveredMetricID == metric.id
            // No app haptic here: the physical click already plays its own press/release haptics, and an
            // added pulse at mouse-up stacks against the release click and reads as a double vibration.
            Button {
                if blocked {
                    layout.notePinDenied(metric.id)
                } else {
                    layout.togglePin(metric.id)
                }
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            .opacity(visible ? (blocked ? 0.35 : 1) : 0)
            .allowsHitTesting(visible)
            .hoverTooltip(pinHelp(metric))
            .animation(Motion.spring, value: visible)
            .animation(Motion.spring, value: pinned)
        }
    }

    private func pinHelp(_ metric: WidgetDescriptor) -> String {
        if layout.isPinned(metric.id) { return "Unpin" }
        return layout.pinDenialReason(metric.id) ?? "Pin to menu bar"
    }

    private func providerDragGesture(for group: ProviderMetrics) -> some Gesture {
        reorderDragGesture(
            id: group.provider.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: group, value: $0) },
            orderedIDs: { layout.customizeGroups.map(\.provider.id) },
            reorder: { layout.reorderProvider(dragged: group.provider.id, target: $0) }
        )
    }

    private func metricDragGesture(for metricID: String, providerID: String, title: String) -> some Gesture {
        reorderDragGesture(
            id: metricID,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { makeMetricLift(metricID: metricID, title: title, value: $0) },
            orderedIDs: { reorderTargetIDs(for: providerID) },
            reorder: { target in
                let current = reorderTargetIDs(for: providerID)
                guard let next = LayoutStore.reordered(current, dragged: metricID, target: target) else {
                    return false
                }
                return layout.applyMetricDividerOrder(next, dividerID: expandedDividerID(for: providerID), in: providerID)
            }
        )
    }

    private func reorderTargetIDs(for providerID: String) -> [String] {
        layout.metricOrderWithDivider(for: providerID, dividerID: expandedDividerID(for: providerID))
    }

    private func expandedDividerID(for providerID: String) -> String {
        "\(providerID)::expanded-divider"
    }

    private func makeProviderLift(for group: ProviderMetrics, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: group.provider.id,
            payload: .customizeProvider(
                provider: group.provider,
                rows: group.metrics.map(\.title)
            ),
            value: value,
            frames: rowFrames
        )
    }

    private func makeMetricLift(metricID: String, title: String, value: DragGesture.Value) -> ReorderLift? {
        return ReorderLift.make(
            id: metricID,
            payload: .customizeMetric(title: title),
            value: value,
            frames: rowFrames
        )
    }
}

/// A single horizontal line, used as the dashed "Shown on expand" rule. A plain `Divider` can't carry
/// a dash pattern, so the separator strokes this shape instead.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private enum CustomizeMetricCardRow: Identifiable {
    case metric(WidgetDescriptor)
    case divider

    var id: String {
        switch self {
        case .metric(let metric):
            "metric:\(metric.id)"
        case .divider:
            "expanded-divider"
        }
    }
}

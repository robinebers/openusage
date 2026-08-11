import SwiftUI

/// The Customize detail for one provider (L2): two distinct cards — **Always Visible** (shown on the
/// dashboard card) and **On Demand** (tucked behind the card's caret). Drag a metric by its grip
/// onto a row in the other card to move it across; an empty card shows a small dashed "Drag metrics
/// here" drop zone that's also the drop target for moving a metric into it. Each metric row is
/// grip · name · star · toggle (drag left, toggle right — same shape as the provider rows). The star
/// is always visible: outline when not starred, filled accent when starred; tapping it pops a
/// transient confirmation pill (and an orange denial pill over the per-provider cap). Providers that
/// need an API key get their own "API Key" section here too.
///
/// The drag gesture lives on the container, not on each row. With a per-row gesture, SwiftUI tears
/// down the dragged row (and its gesture) when it crosses between the two cards' `ForEach`es,
/// dropping the drag mid-gesture. A single container-level gesture stays attached to the persistent
/// section stack, so the drag survives the cross — no force-drop, no stuck overlay. Each row's grip
/// publishes its own frame so the container gesture can tell which row a drag started on.
struct CustomizeProviderDetailView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(AppContainer.self) private var container
    let providerID: String
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let rowFrames: [String: CGRect]

    @State private var activeMetricID: String?
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        if let group = layout.customizeDetail(for: providerID) {
            VStack(alignment: .leading, spacing: density.sectionSpacing) {
                metricSections(group)
                    .simultaneousGesture(metricDragGesture())
                if let keyProvider = container.apiKeyProviders.first(where: { $0.provider.id == providerID }) {
                    APIKeysSection(provider: keyProvider)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.spring, value: layout.expandedMetricIDs)
        } else {
            // Unknown provider — L1 only lists known providers, so this is unreachable in practice.
            EmptyView()
        }
    }

    private func metricSections(_ group: ProviderMetrics) -> some View {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            metricSection("Always Visible", metrics: group.alwaysShownMetrics, providerID: group.provider.id)
            metricSection("On Demand", metrics: group.expandedMetrics, providerID: group.provider.id)
        }
    }

    // MARK: - Metric sections

    private func metricSection(_ title: String, metrics: [WidgetDescriptor], providerID: String) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                if metrics.isEmpty {
                    emptyDropZone(providerID: providerID)
                } else {
                    ForEach(metrics, id: \.id) { metric in
                        metricRow(metric, in: providerID)
                    }
                }
            }
            .cardSurface()
        }
    }

    /// A small dashed drop target shown when a section is empty, so there's always somewhere to drop
    /// a metric into. It carries the divider's reorder frame — dropping a metric here moves it into
    /// this section via `applyMetricDividerOrder` (the sentinel sits at the empty section's edge).
    private func emptyDropZone(providerID: String) -> some View {
        let yOutset = max(0, (density.estimatedMetricRowHeight - 30) / 2)
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(.tertiary)
            .frame(height: 30)
            .padding(8)
            .overlay(
                Text("Drag metrics here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            )
            .reorderFrame(id: expandedDividerID(for: providerID), in: .named(reorderSpaceName), yOutset: yOutset)
            .accessibilityLabel("Drag metrics here")
    }

    private func metricRow(_ metric: WidgetDescriptor, in providerID: String) -> some View {
        let isActive = activeMetricID == metric.id
        return CustomizeMetricRow(
            title: metric.title,
            // The grip is visual-only and publishes its frame (id "grip:<metric>") so the container
            // gesture can tell which row a drag started on. The drag gesture itself is on the section
            // stack, not the grip — see `metricDragGesture`.
            handle: { grip in
                AnyView(grip.reorderFrame(id: "grip:\(metric.id)", in: .named(reorderSpaceName)))
            },
            trailing: {
                StarButton(metric: metric)
                Toggle("", isOn: Binding(
                    get: { layout.isMetricEnabled(metric.id) },
                    set: { layout.setMetricEnabled(metric.id, $0) }
                ))
                .settingsSwitchStyle()
            }
        )
        .contentShape(Rectangle())
        .opacity(isActive ? 0 : 1)
        .reorderFrame(id: metric.id, in: .named(reorderSpaceName))
    }

    // MARK: - Container drag-reorder

    /// One drag gesture on the section stack (not per-row), so it survives a metric crossing between
    /// the two cards. On start, the grip under the pointer identifies the dragged metric; afterwards
    /// it tracks the pointer, hit-tests row + divider frames, and reorders through
    /// `applyMetricDividerOrder`.
    private func metricDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(reorderSpaceName))
            .onChanged { value in
                if activeMetricID == nil {
                    if let id = metricID(at: value.startLocation) {
                        activeMetricID = id
                        if let lift = makeLift(metricID: id, value: value) {
                            reorderLift = lift
                        }
                    }
                }
                guard let id = activeMetricID else { return }
                reorderLift?.location = value.location
                let divider = expandedDividerID(for: providerID)
                let ordered = reorderTargetIDs(for: providerID)
                guard let target = reorderTarget(at: value.location, in: rowFrames, excluding: id, orderedIDs: ordered),
                      let next = LayoutStore.reordered(ordered, dragged: id, target: target) else { return }
                withAnimation(Motion.spring) {
                    _ = layout.applyMetricDividerOrder(next, dragged: id, dividerID: divider, in: providerID)
                }
            }
            .onEnded { _ in
                activeMetricID = nil
                reorderLift = nil
            }
    }

    /// The metric a drag started on, by hit-testing the drag start against the grip frames
    /// ("grip:<metric>" entries in `rowFrames`). Nil when the drag didn't start on a grip.
    private func metricID(at point: CGPoint) -> String? {
        for (key, frame) in rowFrames {
            guard key.hasPrefix("grip:"), frame.insetBy(dx: 0, dy: -2).contains(point) else { continue }
            return String(key.dropFirst("grip:".count))
        }
        return nil
    }

    private func reorderTargetIDs(for providerID: String) -> [String] {
        layout.metricOrderWithDivider(for: providerID, dividerID: expandedDividerID(for: providerID))
    }

    private func expandedDividerID(for providerID: String) -> String {
        "\(providerID)::expanded-divider"
    }

    private func makeLift(metricID: String, value: DragGesture.Value) -> ReorderLift? {
        let title = layout.customizeDetail(for: providerID)?.metrics.first { $0.id == metricID }?.title ?? ""
        return ReorderLift.make(id: metricID, payload: .customizeMetric(title: title), value: value, frames: rowFrames)
    }
}

/// The star (menu-bar pin) control on a metric row — always visible: an outline star when not
/// starred, a filled accent star when starred. Tapping it pops a transient confirmation pill (green
/// "Starred for menu bar" / "Removed from menu bar"); a denied tap over the per-provider cap shakes
/// the star and pops an orange denial pill. No tooltips.
private struct StarButton: View {
    let metric: WidgetDescriptor
    @Environment(LayoutStore.self) private var layout
    @State private var shakeTrigger = 0

    var body: some View {
        if metric.pinnable {
            let pinned = layout.isPinned(metric.id)
            Button {
                if layout.canPin(metric.id) {
                    layout.togglePin(metric.id)
                    layout.presentCustomizationNotice(pinned ? "Removed from menu bar" : "Starred for menu bar")
                } else {
                    shakeTrigger += 1
                    layout.presentCustomizationNotice(layout.pinDenialReason(metric.id) ?? "Up to 2 stars per provider", tone: .notice)
                }
            } label: {
                Image(systemName: pinned ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            .denyShake(trigger: shakeTrigger)
            .animation(Motion.spring, value: pinned)
        }
    }
}

import SwiftUI

/// The Customize detail for one provider (L2): a provider header (mark + name + Active/Inactive +
/// the master on/off toggle) over a single card holding two labeled sections — **Always Visible**
/// (metrics shown above the dashboard caret) and **On Demand** (metrics behind the caret) — split by
/// the dashed divider. Dragging a metric across that divider moves it between sections via the
/// existing `applyMetricDividerOrder` sentinel mechanic. Each metric row is toggle · name · star ·
/// grip (the star is the menu-bar pin). Available even when the provider is disabled: the sections
/// render dimmed but stay editable, with the header toggle as the primary re-enable action.
struct CustomizeProviderDetailView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(AppContainer.self) private var container
    let providerID: String
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let rowFrames: [String: CGRect]

    @State private var activeMetricID: String?
    @State private var hoveredMetricID: String?
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        if let group = layout.customizeDetail(for: providerID),
           let provider = layout.provider(id: providerID) {
            let isEnabled = container.enablement.isEnabled(providerID)
            VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
                providerHeader(provider, isEnabled: isEnabled)
                metricCard(group)
                    .opacity(isEnabled ? 1 : 0.6)
                // Providers that need a user-supplied key (OpenRouter today) get their own "API Key"
                // section here — the same editor logic the Settings ▸ API Keys card used, scoped to this
                // one provider. Hidden for providers that don't need a key.
                if let keyProvider = container.apiKeyProviders.first(where: { $0.provider.id == providerID }) {
                    APIKeysSection(providers: [keyProvider])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.spring, value: layout.expandedMetricIDs)
        } else {
            // Unknown provider — L1 only lists known providers, so this is unreachable in practice.
            EmptyView()
        }
    }

    // MARK: - Provider header

    private func providerHeader(_ provider: Provider, isEnabled: Bool) -> some View {
        HStack(spacing: 10) {
            ProviderIcon(source: provider.icon)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(provider.displayName)
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(isEnabled ? Theme.positive : AnyShapeStyle(Color.secondary.opacity(0.6)))
                        .frame(width: 6, height: 6)
                    Text(isEnabled ? "Active" : "Inactive")
                        .font(.system(size: density.planBadgePointSize))
                        .foregroundStyle(isEnabled ? Theme.positive : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 8)
            // The master on/off toggle — the primary action, especially when the provider is disabled.
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { container.enablement.setEnabled($0, for: provider.id) }
            ))
            .settingsSwitchStyle()
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Metric card

    private func metricCard(_ group: ProviderMetrics) -> some View {
        VStack(spacing: 0) {
            ForEach(metricCardRows(for: group)) { row in
                switch row {
                case .sectionLabel(let label):
                    sectionLabel(label)
                case .metric(let metric):
                    metricRow(metric, in: group.provider.id)
                case .divider:
                    expandedDivider(providerID: group.provider.id)
                }
            }
        }
        .cardSurface()
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func metricCardRows(for group: ProviderMetrics) -> [CustomizeMetricCardRow] {
        [.sectionLabel("Always Visible")]
            + group.alwaysShownMetrics.map(CustomizeMetricCardRow.metric)
            + [.divider]
            + [.sectionLabel("On Demand")]
            + group.expandedMetrics.map(CustomizeMetricCardRow.metric)
    }

    private func metricRow(_ metric: WidgetDescriptor, in providerID: String) -> some View {
        let isActive = activeMetricID == metric.id
        return CustomizeMetricRow(
            title: metric.title,
            handle: { $0.highPriorityGesture(metricDragGesture(for: metric.id, providerID: providerID, title: metric.title)) },
            leading: {
                Toggle("", isOn: Binding(
                    get: { layout.isMetricEnabled(metric.id) },
                    set: { layout.setMetricEnabled(metric.id, $0) }
                ))
                .settingsSwitchStyle()
            },
            trailing: {
                starButton(metric)
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

    /// The star (menu-bar pin) control on a metric row: a filled star when starred, an outline star on
    /// row hover otherwise. At a cap the star dims but stays clickable — a denied click routes through
    /// `notePinDenied`, which surfaces the reason in the footer (WhatsApp-style feedback) instead of
    /// silently doing nothing.
    @ViewBuilder
    private func starButton(_ metric: WidgetDescriptor) -> some View {
        if metric.pinnable {
            let pinned = layout.isPinned(metric.id)
            let blocked = !layout.canPin(metric.id)   // false when pinned, so unstar always works
            let visible = pinned || hoveredMetricID == metric.id
            Button {
                if blocked {
                    layout.notePinDenied(metric.id)
                } else {
                    layout.togglePin(metric.id)
                }
            } label: {
                Image(systemName: pinned ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            .opacity(visible ? (blocked ? 0.35 : 1) : 0)
            .allowsHitTesting(visible)
            .hoverTooltip(starHelp(metric))
            .animation(Motion.spring, value: visible)
            .animation(Motion.spring, value: pinned)
        }
    }

    private func starHelp(_ metric: WidgetDescriptor) -> String {
        if layout.isPinned(metric.id) { return "Unstar" }
        return layout.pinDenialReason(metric.id) ?? "Star for menu bar"
    }

    // MARK: - Divider

    /// The single dashed boundary between Always Visible and On Demand. Kept visually simple so it
    /// reads as one drop target instead of several moving controls.
    private func expandedDivider(providerID: String) -> some View {
        let yOutset = max(0, (density.estimatedMetricRowHeight - density.customizeDividerRowHeight) / 2)
        return dashedRule
            .padding(.horizontal, 12)
            .frame(height: density.customizeDividerRowHeight)
            .reorderFrame(id: expandedDividerID(for: providerID), in: .named(reorderSpaceName), yOutset: yOutset)
            .accessibilityLabel("On Demand divider")
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

    // MARK: - Metric drag-reorder

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
                return layout.applyMetricDividerOrder(next, dragged: metricID, dividerID: expandedDividerID(for: providerID), in: providerID)
            }
        )
    }

    private func reorderTargetIDs(for providerID: String) -> [String] {
        layout.metricOrderWithDivider(for: providerID, dividerID: expandedDividerID(for: providerID))
    }

    private func expandedDividerID(for providerID: String) -> String {
        "\(providerID)::expanded-divider"
    }

    private func makeMetricLift(metricID: String, title: String, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: metricID,
            payload: .customizeMetric(title: title),
            value: value,
            frames: rowFrames
        )
    }
}

/// A single horizontal line, used as the dashed On Demand rule. A plain `Divider` can't carry a dash
/// pattern, so the separator strokes this shape instead.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private enum CustomizeMetricCardRow: Identifiable {
    case sectionLabel(String)
    case metric(WidgetDescriptor)
    case divider

    var id: String {
        switch self {
        case .sectionLabel(let label):
            "section:\(label)"
        case .metric(let metric):
            "metric:\(metric.id)"
        case .divider:
            "expanded-divider"
        }
    }
}

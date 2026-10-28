import SwiftUI

/// The Accounts detail for one account (L2). The title bar carries the account's name, which renames
/// in place (`PopoverTopBar`). Below it is one card with every metric the account supports, in its
/// saved order, and a destructive Remove Account row that asks for confirmation. Each metric row is
/// grip · name · star · toggle: drag the grip to reorder, flip the toggle to show or hide the metric on
/// the dashboard. The star is always visible: outline when not starred, filled accent when starred;
/// tapping it pops a transient confirmation pill (and an orange denial pill over the per-provider cap).
struct AccountDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    let providerID: String
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let frameStore: ReorderFrameStore

    @State private var activeMetricID: String?
    @State private var isConfirmingRemoval = false

    var body: some View {
        if let group = layout.customizeDetail(for: providerID) {
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                VStack(spacing: 0) {
                    ForEach(group.metrics, id: \.id) { metric in
                        metricRow(metric)
                    }
                }
                .cardSurface()
                removeAccountRow(group.provider)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Unknown account — L1 only lists known accounts, and removing one returns to L1 first.
            EmptyView()
        }
    }

    // MARK: - Remove

    private func removeAccountRow(_ provider: Provider) -> some View {
        Button(role: .destructive) {
            isConfirmingRemoval = true
        } label: {
            Text("Remove Account…")
                .foregroundStyle(Color(nsColor: .systemRed))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, PanelMetrics.controlRowPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface()
        .confirmationDialog(
            "Remove \(provider.fullName)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) { removeAccount() }
        } message: {
            Text("Its sign-in is deleted from this Mac. You can add the account again at any time.")
        }
    }

    /// Back to the list first, so the removed row animates out of L1 instead of the detail vanishing.
    private func removeAccount() {
        guard let account = container.accounts.account(cardID: providerID) else { return }
        withAnimation(Motion.spring) { layout.customizeProviderID = nil }
        container.accounts.remove(account.id)
    }

    // MARK: - Metrics

    private func metricRow(_ metric: WidgetDescriptor) -> some View {
        CustomizeMetricRow(
            title: metric.title,
            grip: { ReorderGrip().highPriorityGesture(metricDragGesture(for: metric)) },
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
        .opacity(activeMetricID == metric.id ? 0 : 1)
        .reorderFrame(id: metric.id, in: .named(reorderSpaceName))
    }

    private func metricDragGesture(for metric: WidgetDescriptor) -> some Gesture {
        reorderDragGesture(
            id: metric.id,
            coordinateSpaceName: reorderSpaceName,
            frameStore: frameStore,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { value in
                ReorderLift.make(
                    id: metric.id,
                    preview: AnyView(
                        CustomizeMetricRow(title: metric.title, grip: { ReorderGrip() }) {
                            CustomizeStarPlaceholder()
                            CustomizeSwitchPlaceholder()
                        }
                        .liftedRowSurface()
                    ),
                    value: value,
                    frames: frameStore.frames
                )
            },
            orderedIDs: { layout.orderedSupportedMetrics(for: providerID).map(\.id) },
            reorder: { layout.reorderMetric(dragged: metric.id, target: $0, in: providerID) }
        )
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

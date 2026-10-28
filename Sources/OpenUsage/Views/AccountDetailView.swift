import SwiftUI

struct AccountDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
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
            EmptyView()
        }
    }

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

    private func removeAccount() {
        guard let account = container.accounts.account(cardID: providerID) else { return }
        withAnimation(Motion.spring) { popover.customizeProviderID = nil }
        container.accounts.remove(account.id)
    }

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
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
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

private struct StarButton: View {
    let metric: WidgetDescriptor
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    @State private var shakeTrigger = 0

    var body: some View {
        let pinned = layout.isPinned(metric.id)
        Button {
            if layout.canPin(metric.id) {
                layout.togglePin(metric.id)
                popover.accountsNotice.present(CustomizationNoticeContent(message: pinned ? "Removed from menu bar" : "Starred for menu bar", tone: .positive))
            } else {
                shakeTrigger += 1
                popover.accountsNotice.present(CustomizationNoticeContent(message: layout.pinDenialReason(metric.id) ?? "Up to 2 stars per provider", tone: .notice))
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

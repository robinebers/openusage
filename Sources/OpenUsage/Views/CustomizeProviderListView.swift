import SwiftUI

/// The Customize provider list (L1): every known provider as a row, in the user's saved order —
/// including disabled ones (greyed), so the user can re-enable them or open their detail. Each row
/// carries the master on/off toggle, an Active/Inactive status, a metric-count badge, and a chevron
/// into the provider's detail (L2). Providers drag-reorder by the leading grip; tapping a row opens
/// L2 (`layout.customizeProviderID = id`).
struct CustomizeProviderListView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(AppContainer.self) private var container
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let rowFrames: [String: CGRect]

    @State private var activeProviderID: String?
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private var orderedRows: [ProviderRow] { layout.customizeProviderRows }

    var body: some View {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            VStack(spacing: 0) {
                ForEach(orderedRows) { row in
                    providerRow(row)
                }
            }
            .cardSurface()
            // App behavior/appearance options live on the other screen; catch users who came here
            // hunting for them once they've scanned past the provider list.
            ScreenCrossLinkRow(
                systemImage: "gearshape",
                title: "Settings",
                subtitle: "Notifications, appearance and more",
                destination: .settings
            )
        }
        .animation(Motion.spring, value: orderedRows.map(\.id))
    }

    private func providerRow(_ row: ProviderRow) -> some View {
        ProviderListRow(
            provider: row.provider,
            isEnabled: row.isEnabled,
            metricCount: row.metricCount,
            // The grip leads the tappable bar; a tap opens L2, a drag reorders. Drag-reorder is enabled
            // only for active providers — `reorderProvider` operates on the enabled set, so a disabled
            // row's grip stays inert (the row still opens/toggles).
            handle: { grip in
                if row.isEnabled {
                    AnyView(grip.highPriorityGesture(providerDragGesture(for: row)))
                } else {
                    grip
                }
            },
            onToggle: { container.enablement.setEnabled($0, for: row.id) },
            onOpen: { withAnimation(Motion.spring) { layout.customizeProviderID = row.id } }
        )
        .opacity(activeProviderID == row.id ? 0 : 1)
        .reorderFrame(id: row.id, in: .named(reorderSpaceName))
    }

    private func providerDragGesture(for row: ProviderRow) -> some Gesture {
        reorderDragGesture(
            id: row.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: row, value: $0) },
            // Hit-test only enabled providers (the set `reorderProvider` can actually move); disabled
            // rows keep their tail position and aren't reorder targets.
            orderedIDs: { layout.customizeGroups.map(\.provider.id) },
            reorder: { layout.reorderProvider(dragged: row.id, target: $0) }
        )
    }

    private func makeProviderLift(for row: ProviderRow, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: row.id,
            payload: .customizeProviderRow(provider: row.provider, isEnabled: row.isEnabled, metricCount: row.metricCount),
            value: value,
            frames: rowFrames
        )
    }
}

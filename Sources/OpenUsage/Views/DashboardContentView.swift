import SwiftUI

/// The dashboard-only scrolling content. Screen switching, panel sizing, fixed bars, keyboard handling,
/// and close/reset behavior stay with `DashboardView`.
struct DashboardContentView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    let reorderSpaceName: String

    @Binding var reorderLift: ReorderLift?
    @Binding var scrollPosition: ScrollPosition

    @Environment(UpdaterController.self) private var updater
    @State private var isAddingAccount = false

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // A pending update found by a scheduled Sparkle check tops everything: it's the reminder
                // the buried Sparkle window can't deliver for a dockless app.
                if let updateVersion = updater.availableUpdateVersion {
                    UpdateBannerCard(version: updateVersion)
                        .padding(.bottom, PanelMetrics.sectionSpacing)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                widgetContent
            }
            .animation(Motion.spring, value: updater.availableUpdateVersion)
            .padding(PanelMetrics.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scrollPosition)
        .sheet(isPresented: $isAddingAccount) {
            AddAccountSheet(store: container.accounts)
        }
    }

    @ViewBuilder
    private var widgetContent: some View {
        if layout.displayGroups.isEmpty {
            EmptyDashboardView { isAddingAccount = true }
        } else {
            WidgetGroupedListView(
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift
            )
        }
    }
}

import SwiftUI

struct DashboardContentView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    let reorderSpaceName: String

    @Binding var reorderLift: ReorderLift?
    @Binding var scrollPosition: ScrollPosition

    @Environment(UpdaterController.self) private var updater
    @AppStorage(DashboardTab.key) private var tab = DashboardTab.priority
    @State private var accountToOpen: String?

    /// Half the space on each side of the content: it and the bar beside it each hold this much.
    static let barGap: CGFloat = 7

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
            .padding(.horizontal, PanelMetrics.margin)
            .padding(.vertical, Self.barGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scrollPosition)
        .onChange(of: tab) { _, _ in
            guard let accountToOpen else {
                scrollPosition.scrollTo(edge: .top)
                return
            }
            self.accountToOpen = nil
            // All Metrics mounts with this change, so its accounts only exist to scroll to on the next turn.
            Task { @MainActor in scrollPosition.scrollTo(id: accountToOpen, anchor: .top) }
        }
    }

    @ViewBuilder
    private var widgetContent: some View {
        if layout.registry.providers.isEmpty {
            EmptyDashboardView { popover.isAddingAccount = true }
        } else {
            switch tab {
            case .priority:
                PriorityDashboardView { accountID in
                    accountToOpen = accountID
                    tab = .allMetrics
                }
            case .allMetrics:
                WidgetGroupedListView(
                    reorderSpaceName: reorderSpaceName,
                    reorderLift: $reorderLift
                )
            }
        }
    }
}

import SwiftUI

struct PopoverTopBar: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    let screen: PopoverScreen

    @ViewBuilder
    var body: some View {
        switch screen {
        case .dashboard:
            CapsuleSegments(options: DashboardTab.allCases.map { ($0, $0.label) }, selection: Bindable(popover).dashboardTab)
                .padding(.horizontal, PanelMetrics.margin)
                .padding(.top, PanelMetrics.margin)
                .padding(.bottom, DashboardContentView.barGap)
        case .accounts:
            if let providerID = popover.customizeProviderID, let provider = layout.provider(id: providerID) {
                navigationBar(back: { popover.back() }) {
                    AccountTitle(provider: provider)
                } trailing: {
                    logo(for: provider)
                }
            } else if let hubID = popover.customizeHubID, let hub = container.accounts.hubs.first(where: { $0.id == hubID }) {
                navigationBar(back: { popover.back() }) {
                    Text(hub.host)
                        .truncationMode(.middle)
                } trailing: {
                    ProviderIcon(id: CLIProxyHub.markID, side: 22, inset: 0.04)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
            } else {
                navigationBar(back: { popover.back() }) {
                    Text("Accounts")
                } trailing: {
                    EmptyView()
                }
            }
        case .settings:
            VStack(spacing: 10) {
                ZStack {
                    Text("Settings")
                        .font(.headline)
                    HStack(spacing: 0) {
                        backButton { popover.back() }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 28)
                SettingsTabBar()
            }
            .padding(.horizontal, PanelMetrics.margin)
            .padding(.top, PanelMetrics.margin)
            .padding(.bottom, DashboardContentView.barGap)
        }
    }

    private func navigationBar<Title: View, Trailing: View>(
        back: @escaping () -> Void,
        @ViewBuilder title: () -> Title,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        ZStack {
            title()
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                backButton(action: back)
                Spacer(minLength: 8)
                trailing()
            }
        }
        .padding(.horizontal, PanelMetrics.margin)
        .frame(height: 36, alignment: .bottom)
        .frame(maxWidth: .infinity)
    }

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.severityColor(.normal))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTooltip("Back")
        .accessibilityLabel("Back")
    }

    private func logo(for provider: Provider) -> some View {
        AccountIcon(provider: provider, side: 22, inset: 0.04)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}

private struct SettingsTabBar: View {
    @Environment(PopoverState.self) private var popover
    @Environment(\.reduceAnimations) private var reduceAnimations

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab(for: $0) }
        }
    }

    private func tab(for tab: SettingsTab) -> some View {
        let isSelected = popover.settingsTab == tab
        return Button {
            popover.settingsTab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 16))
                    .frame(height: 20)
                Text(tab.title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(Theme.severityColor(.normal)) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .padding(.top, 5)
            .padding(.bottom, 4)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.controlFill)
                }
            }
            .animation(reduceAnimations ? nil : .easeInOut(duration: 0.18), value: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AccountTitle: View {
    let provider: Provider

    @Environment(AccountRenameStore.self) private var renaming
    @State private var isHovered = false

    var body: some View {
        if let edit = renaming.edit, edit.providerID == provider.id {
            InlineRenameField(renaming: renaming, edit: edit)
                .multilineTextAlignment(.center)
        } else {
            Button {
                renaming.begin(provider.id)
            } label: {
                Text(provider.accountName)
                    .concealingAccountName(of: provider)
                    .hoverHighlight(isHovered)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .hoverTooltip("Rename Account")
            .accessibilityLabel("\(provider.fullName), Rename Account")
        }
    }
}

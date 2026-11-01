import SwiftUI

struct PopoverTopBar: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    let screen: PopoverScreen
    let height: CGFloat
    let horizontalPadding: CGFloat

    @ViewBuilder
    var body: some View {
        switch screen {
        case .dashboard:
            DashboardTabBar(horizontalPadding: horizontalPadding)
        case .accounts:
            if let providerID = popover.customizeProviderID, let provider = layout.provider(id: providerID) {
                navigationBar(back: { popover.back() }) {
                    AccountTitle(provider: provider)
                } trailing: {
                    logo(for: provider)
                }
            } else {
                navigationBar(back: { popover.back() }) {
                    Text("Accounts")
                } trailing: {
                    addAccountButton
                }
            }
        case .settings:
            navigationBar {
                popover.back()
            } title: {
                Text("Settings")
            } trailing: {
                EmptyView()
            }
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
        .padding(.horizontal, horizontalPadding)
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
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

    private var addAccountButton: some View {
        Button {
            popover.isAddingAccount = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Theme.controlFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverTooltip("Add Account")
        .accessibilityLabel("Add Account")
    }
}

private struct DashboardTabBar: View {
    let horizontalPadding: CGFloat

    @AppStorage(DashboardTab.key) private var tab = DashboardTab.priority
    @Environment(\.reduceAnimations) private var reduceAnimations
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DashboardTab.allCases, id: \.self) { segment($0) }
        }
        .padding(2)
        .frame(height: 28)
        .background(Theme.controlFill, in: Capsule())
        .padding(.horizontal, horizontalPadding)
        .padding(.top, PanelMetrics.margin)
        .padding(.bottom, DashboardContentView.barGap)
    }

    private func segment(_ candidate: DashboardTab) -> some View {
        let isSelected = tab == candidate
        return Button {
            withAnimation(reduceAnimations ? nil : Motion.spring) { tab = candidate }
        } label: {
            Text(candidate.label)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Theme.segmentThumb)
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Capsule())
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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quaternary)
                            .opacity(isHovered ? 1 : 0)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .hoverTooltip("Rename Account")
            .accessibilityLabel("\(provider.fullName), Rename Account")
        }
    }
}

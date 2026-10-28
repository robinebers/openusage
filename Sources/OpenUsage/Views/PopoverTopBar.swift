import SwiftUI

/// A screen's navigation chrome. It reads the screen it belongs to, not the destination, so during a
/// slide each mounted page carries its own bar and the bar travels with its content.
struct PopoverTopBar: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    /// The screen this bar belongs to — the page that hosts it, so a switch can't put the incoming
    /// screen's bar over the outgoing one.
    let screen: PopoverScreen
    let height: CGFloat
    let horizontalPadding: CGFloat

    @ViewBuilder
    var body: some View {
        switch screen {
        case .dashboard:
            EmptyView()
        case .accounts:
            if let providerID = popover.customizeProviderID, let provider = layout.provider(id: providerID) {
                navigationBar(back: accountsBack) {
                    AccountTitle(provider: provider)
                } trailing: {
                    logo(for: provider)
                }
            } else {
                navigationBar(back: accountsBack) {
                    Text("Accounts")
                } trailing: {
                    addAccountButton
                }
            }
        case .settings:
            navigationBar {
                withAnimation(Motion.modeSwitch) { popover.screen = .dashboard }
            } title: {
                Text("Settings")
            } trailing: {
                EmptyView()
            }
        }
    }

    private func accountsBack() {
        if popover.customizeProviderID != nil {
            withAnimation(Motion.spring) { popover.customizeProviderID = nil }
        } else {
            withAnimation(Motion.modeSwitch) { popover.screen = .dashboard }
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
                // Keeps a long title, or the rename field that replaces it, clear of the buttons.
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
        .barGlass()
    }

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
                .frame(width: 16, height: 16)
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .hoverTooltip("Back")
        .accessibilityLabel("Back")
    }

    /// The account's provider mark, filling the back button's footprint on the other side so the
    /// title stays centred. Decoration only: the title already names the account.
    private func logo(for provider: Provider) -> some View {
        ProviderIcon(id: provider.icon, side: 22, inset: 0.04)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }

    /// Opens the account list's Add Account sheet.
    private var addAccountButton: some View {
        Button {
            popover.isAddingAccount = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .hoverTooltip("Add Account")
        .accessibilityLabel("Add Account")
    }
}

/// The Accounts detail title: the account's name, which a click turns into an inline rename field
/// (`AccountRenameStore`). A hover highlight marks it as clickable.
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

import SwiftUI

/// Fixed popover navigation chrome. It always reads the destination screen, so both pages mounted
/// during a slide draw the same bar and only the scrolling content moves.
struct PopoverTopBar: View {
    let layout: LayoutStore
    let height: CGFloat
    let horizontalPadding: CGFloat
    let onResetAll: () -> Void

    @Binding var isPresentingResetAllConfirm: Bool

    @ViewBuilder
    var body: some View {
        switch layout.screen {
        case .dashboard:
            EmptyView()
        case .customize:
            if let providerID = layout.customizeProviderID {
                navigationBar(title: customizeTitle, back: customizeBack) {
                    resetButton(for: providerID)
                }
            } else {
                navigationBar(title: customizeTitle, back: customizeBack) {
                    resetAllButton
                }
                .alert("Reset All Customization?", isPresented: $isPresentingResetAllConfirm) {
                    Button("Reset All", role: .destructive) {
                        withAnimation(Motion.spring) { onResetAll() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Turns providers back on for the tools you have installed and resets every provider's metrics and order. Are you sure?")
                }
            }
        case .settings:
            navigationBar(title: "Settings") {
                withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
            } trailing: {
                EmptyView()
            }
        }
    }

    private var customizeTitle: String {
        layout.customizeProviderID.flatMap { layout.provider(id: $0)?.displayName } ?? "Customize"
    }

    private func customizeBack() {
        if layout.customizeProviderID != nil {
            withAnimation(Motion.spring) { layout.customizeProviderID = nil }
        } else {
            withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
        }
    }

    private func navigationBar<Trailing: View>(
        title: String,
        back: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        ZStack {
            Text(title)
                .font(.headline)
                .lineLimit(1)
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

    private func resetButton(for providerID: String) -> some View {
        Button {
            withAnimation(Motion.spring) { layout.resetProvider(providerID) }
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .hoverTooltip("Reset \(layout.provider(id: providerID)?.displayName ?? providerID)")
        .accessibilityLabel("Reset")
    }

    private var resetAllButton: some View {
        Button {
            isPresentingResetAllConfirm = true
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .hoverTooltip("Reset All Customization")
        .accessibilityLabel("Reset All Customization")
    }
}

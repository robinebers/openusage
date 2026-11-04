import SwiftUI

struct AccountListRow<Grip: View>: View {
    @AppStorage(PrivacyModeSetting.key) private var privacyMode = false
    let provider: Provider
    @ViewBuilder var grip: Grip
    var onOpen: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            grip

            HStack(spacing: 8) {
                ProviderIcon(id: provider.icon, side: 18)
                Text(provider.displayName)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
                if provider.labelBesideName != nil {
                    AccountNameText(provider: provider, privacyMode: privacyMode)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }

            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(PrivacyModeSetting.fullName(provider, isEnabled: privacyMode))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, PanelMetrics.controlRowPadding)
    }
}

struct ReorderGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
    }
}

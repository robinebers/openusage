import SwiftUI

/// One row in the Customize provider list (L1). Carries the provider mark + name, an Active/Inactive
/// status label, a metric-count badge, the master on/off toggle, and a chevron into the provider's
/// detail (L2). The leading grip is the drag handle for reordering providers — the caller attaches
/// the reorder gesture through `handle` (and leaves it inert for the lifted drag preview). The toggle
/// drives `ProviderEnablementStore`; tapping the name or chevron opens L2. Disabled providers render
/// greyed (`.opacity 0.55`) but stay visible and openable.
struct ProviderListRow<Handle: View>: View {
    let provider: Provider
    let isEnabled: Bool
    let metricCount: Int
    let handle: (AnyView) -> Handle
    var onToggle: ((Bool) -> Void) = { _ in }
    var onOpen: () -> Void = {}

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        HStack(spacing: 10) {
            handle(AnyView(ReorderGrip()))
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    ProviderIcon(source: provider.icon)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(provider.displayName)
                                .font(.system(size: density.headerPointSize, weight: .semibold))
                                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                                .lineLimit(1)
                            countBadge
                        }
                        statusLabel
                    }
                    Spacer(minLength: 8)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Toggle("", isOn: Binding(get: { isEnabled }, set: { onToggle($0) }))
                .settingsSwitchStyle()

            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(provider.displayName)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
        .opacity(isEnabled ? 1 : 0.55)
    }

    private var countBadge: some View {
        Text("\(metricCount)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .accessibilityLabel("\(metricCount) metrics")
    }

    private var statusLabel: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isEnabled ? Theme.positive : AnyShapeStyle(Color.secondary.opacity(0.6)))
                .frame(width: 6, height: 6)
            Text(isEnabled ? "Active" : "Inactive")
                .font(.system(size: density.planBadgePointSize))
                .foregroundStyle(isEnabled ? Theme.positive : AnyShapeStyle(.secondary))
        }
    }
}

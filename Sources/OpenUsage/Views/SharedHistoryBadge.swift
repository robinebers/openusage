import SwiftUI

/// Labels combined history without implying that the card's live limits are shared.
struct SharedHistoryBadge: View {
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        Text("Shared")
            .font(.system(size: density.planBadgePointSize, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .fixedSize()
            .hoverTooltip("Combined data for all accounts")
            .accessibilityLabel("Shared: Combined data for all accounts")
    }
}

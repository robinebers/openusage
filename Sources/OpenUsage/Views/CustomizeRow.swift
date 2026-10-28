import SwiftUI

struct CustomizeMetricRow<Grip: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var grip: Grip
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            grip
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, PanelMetrics.controlRowPadding)
    }
}

struct CustomizeSwitchPlaceholder: View {
    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 28, height: 16)
    }
}

struct CustomizeStarPlaceholder: View {
    var body: some View {
        Image(systemName: "star")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.quaternary)
            .frame(width: 18, height: 18)
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

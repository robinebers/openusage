import SwiftUI

/// The Customize metric row shape, shared by the live row in `CustomizeProviderDetailView` and the
/// lifted drag preview in `ReorderLiftPreview`. The layout is **toggle · label · star · grip** — the
/// toggle leads with the metric name beside it (left-aligned), the star (menu-bar pin) and the drag
/// grip trail. Defining the grip + label slot once is what keeps the floating preview pixel-identical
/// to the row the user is dragging — the two used to be hand-rebuilt separately and drifted apart.
///
/// `leading` is the on/off toggle (live) or a placeholder (preview). `trailing` is the star button
/// (live) or a placeholder (preview). `handle` wraps the trailing drag grip — the live row attaches
/// its reorder gesture through it; the preview leaves it inert.
struct CustomizeMetricRow<Leading: View, Handle: View, Trailing: View>: View {
    let title: String
    /// Wraps the trailing drag grip. The live row threads its reorder gesture through here; the
    /// preview leaves it untouched.
    let handle: (AnyView) -> Handle
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        HStack(spacing: 10) {
            leading
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing
            handle(AnyView(ReorderGrip()))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }
}

extension CustomizeMetricRow where Handle == AnyView {
    /// Static variant for the lifted drag preview: the grip is rendered inert (no gesture).
    init(title: String, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, handle: { $0 }, leading: leading, trailing: trailing)
    }
}

/// The static switch placeholder the lifted previews render where the live row shows a real
/// `Toggle` — a quaternary capsule the size of a small switch, so the floating chip reads like the
/// row without carrying a live control.
struct CustomizeSwitchPlaceholder: View {
    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 28, height: 16)
    }
}

/// The static star placeholder the lifted preview renders where the live row shows the star button.
struct CustomizeStarPlaceholder: View {
    var body: some View {
        Image(systemName: "star")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.quaternary)
            .frame(width: 18, height: 18)
    }
}

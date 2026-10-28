import SwiftUI

/// The Accounts detail's metric row shape, shared by the live row in `AccountDetailView` and the
/// lifted drag preview in `ReorderLiftPreview`. The layout is **grip · label · star · toggle** — the
/// drag grip leads (left), the name follows, and the star + on/off toggle trail on the right. This
/// mirrors the provider row's "drag left, toggle right" arrangement. Defining the grip slot once is
/// what keeps the floating preview pixel-identical to the row the user is dragging.
///
/// `handle` wraps the leading drag grip — the live row threads its reorder gesture through it; the
/// preview leaves it inert. `trailing` is the star button + toggle (live) or placeholders (preview).
struct CustomizeMetricRow<Handle: View, Trailing: View>: View {
    let title: String
    /// Wraps the leading drag grip. The live row threads its reorder gesture through here; the
    /// preview leaves it untouched.
    let handle: (AnyView) -> Handle
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            handle(AnyView(ReorderGrip()))
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, PanelMetrics.controlRowPadding)
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

struct ReorderGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
    }
}

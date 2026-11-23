import SwiftUI

/// The widest label, figure and reset among the metric rows shown together. Every row's columns line up at
/// those widths and each bar runs from its label to its figure, instead of stopping at columns sized for the
/// widest text that could ever show.
struct DashboardColumns: Equatable {
    var label: CGFloat = 0
    var value: CGFloat = 0
    var reset: CGFloat = 0
}

extension EnvironmentValues {
    /// Nil outside a view that shares its rows' columns: a row then sizes each column to its own text.
    @Entry var dashboardColumns: DashboardColumns?
}

private struct DashboardColumnsKey: PreferenceKey {
    static let defaultValue = DashboardColumns()

    static func reduce(value: inout DashboardColumns, nextValue: () -> DashboardColumns) {
        let next = nextValue()
        value.label = max(value.label, next.label)
        value.value = max(value.value, next.value)
        value.reset = max(value.reset, next.reset)
    }
}

private struct SharedDashboardColumns: ViewModifier {
    @State private var columns: DashboardColumns?

    func body(content: Content) -> some View {
        content
            .environment(\.dashboardColumns, columns)
            .onPreferenceChange(DashboardColumnsKey.self) { widths in
                let rounded = DashboardColumns(
                    label: widths.label.rounded(.up), value: widths.value.rounded(.up), reset: widths.reset.rounded(.up)
                )
                if rounded != columns { columns = rounded }
            }
    }
}

extension View {
    /// Lines up the label, figure and reset of every metric row inside.
    func sharingDashboardColumns() -> some View {
        modifier(SharedDashboardColumns())
    }

    /// Offers this view's own width for a shared column. It must be measured before the column's frame is applied,
    /// so the shared width never feeds back into what it measures.
    func reportingDashboardColumn(_ column: WritableKeyPath<DashboardColumns, CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: DashboardColumnsKey.self, value: {
                    var columns = DashboardColumns()
                    columns[keyPath: column] = proxy.size.width
                    return columns
                }())
            }
        }
    }
}

import AppKit
import SwiftUI

enum DashboardGrid {
    static let cardWidth = PanelMetrics.width - 2 * PanelMetrics.margin
    static let cardPadding = Theme.Spacing.xl
    static let cardBottomPadding = Theme.Spacing.xxl
    static let headerGap = Theme.Spacing.xs
    static let sectionSpacing = Theme.Spacing.xxl
    static let accountSpacing: CGFloat = 20
    static let captionGap = Theme.Spacing.l
    static let columnGap = Theme.Spacing.m
    static let amountGap = Theme.Spacing.s
    static let barGap = Theme.Spacing.xs
    static let barHeight: CGFloat = 4
    static let limitGap = Theme.Spacing.l
    static let valueGap = Theme.Spacing.s
    /// The extra space that sets the value rows apart from the bars.
    static let groupGap = Theme.Spacing.l

    static let headerFont: Font = .system(size: 15, weight: .semibold)
    static var headerNSFont: NSFont { .systemFont(ofSize: 15, weight: .semibold) }
    static let planFont: Font = .system(size: 11)
    static var planNSFont: NSFont { .systemFont(ofSize: 11) }
    static let captionFont: Font = .system(size: 11, weight: .semibold)

    static let headerHeight: CGFloat = 24
    static let captionHeight = lineHeight(planNSFont)
    static let iconSize: CGFloat = 16

    static func lineHeight(_ font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font).rounded(.up)
    }

    static func gap(above line: DashboardLine, after previous: DashboardLine?) -> CGFloat {
        guard let previous else { return 0 }
        switch (previous.hasBar, line.hasBar) {
        case (true, true): return limitGap
        case (false, false): return valueGap
        default: return valueGap + groupGap
        }
    }
}

/// An account's rows, spaced by what they are: there are no separators in a card.
struct DashboardLineStack<Row: View>: View {
    let lines: [DashboardLine]
    @ViewBuilder let row: (DashboardLine) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                row(line)
                    .padding(.top, DashboardGrid.gap(above: line, after: index > 0 ? lines[index - 1] : nil))
            }
        }
    }
}

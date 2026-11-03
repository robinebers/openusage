import AppKit
import SwiftUI

enum DashboardGrid {
    static let cardWidth = PanelMetrics.width - 2 * PanelMetrics.margin
    static let cardPadding = Theme.Spacing.xl
    static let cardTopPadding = Theme.Spacing.m
    static let cardBottomPadding = Theme.Spacing.l
    static let headerGap = Theme.Spacing.xs
    static let sectionSpacing = Theme.Spacing.xxl
    static let accountSpacing = Theme.Spacing.m
    static let captionGap = Theme.Spacing.xs
    static let columnGap = Theme.Spacing.m
    static let rowHeight: CGFloat = 22
    static let levelHeight: CGFloat = 9
    static let labelWidth: CGFloat = 90
    static let valueWidth: CGFloat = 52
    static let resetWidth: CGFloat = 48
    static let clockResetWidth: CGFloat = 60

    static let headerFont: Font = .system(size: 15, weight: .semibold)
    static var headerNSFont: NSFont { .systemFont(ofSize: 15, weight: .semibold) }
    static let planFont: Font = .system(size: 10, weight: .medium)
    static var planNSFont: NSFont { .systemFont(ofSize: 11) }
    static let planPadding: CGFloat = 5
    static let captionFont: Font = .system(size: 11, weight: .semibold)

    static let headerHeight: CGFloat = 24
    static let captionHeight = lineHeight(planNSFont)
    static let iconSize: CGFloat = 16

    static func lineHeight(_ font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font).rounded(.up)
    }
}

/// An account's rows, one under the next.
struct DashboardLineStack<Row: View>: View {
    let lines: [DashboardLine]
    @ViewBuilder let row: (DashboardLine) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { row($0) }
        }
    }
}

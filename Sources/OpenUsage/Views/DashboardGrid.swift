import AppKit
import SwiftUI

enum DashboardGrid {
    static let cardWidth = PanelMetrics.width - 2 * PanelMetrics.margin
    static let cardPadding = Theme.Spacing.m
    static let inset = Theme.Spacing.xs
    static let headerGap = Theme.Spacing.xs
    static let sectionSpacing = Theme.Spacing.xxxl
    static let accountSpacing = Theme.Spacing.xxxl
    static let rowHeight: CGFloat = 20
    static let columnGap = Theme.Spacing.m
    static let labelWidth: CGFloat = 86
    static let valueWidth: CGFloat = 52
    static let resetWidth: CGFloat = 56
    static let barHeight: CGFloat = 5

    static let headerFont: Font = .headline
    static var headerNSFont: NSFont { .preferredFont(forTextStyle: .headline) }
    static let planFont: Font = .subheadline
    static var planNSFont: NSFont { .preferredFont(forTextStyle: .subheadline) }
    static let captionFont: Font = .subheadline.weight(.semibold)

    static let headerHeight = lineHeight(headerNSFont)
    static let captionHeight = lineHeight(planNSFont)
    static let iconSize = headerHeight

    static func lineHeight(_ font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font).rounded(.up)
    }
}

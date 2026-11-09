import AppKit
import SwiftUI

enum DashboardGrid {
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
    static let clockResetWidth: CGFloat = 80

    static let headerFont: Font = .system(size: 15, weight: .semibold)
    static let planFont: Font = .system(size: 10, weight: .medium)
    static var planNSFont: NSFont { .systemFont(ofSize: 11) }
    static let planPadding: CGFloat = 5
    static let captionFont: Font = .system(size: 11, weight: .semibold)

    static let headerHeight: CGFloat = 24
    static let captionHeight = NSLayoutManager().defaultLineHeight(for: planNSFont).rounded(.up)
    static let iconSize: CGFloat = 16
}

/// An account's rows, one under the next, or a skeleton row per metric until its first reading.
struct DashboardLineStack<Row: View>: View {
    let account: DashboardAccount
    @ViewBuilder let row: (DashboardLine) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(account.lines) { row($0) }
            if !account.waitingMetricIDs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(account.waitingMetricIDs, id: \.self) { _ in SkeletonMetricRow() }
                }
                .accessibilityElement()
                .accessibilityLabel("Waiting for Usage")
            }
        }
    }
}

/// A metric row's bar, figure, and reset as grey bars in their own columns.
private struct SkeletonMetricRow: View {
    var body: some View {
        HStack(spacing: DashboardGrid.columnGap) {
            Capsule().frame(width: 54, height: 8)
                .frame(width: DashboardGrid.labelWidth, alignment: .leading)
            Capsule().frame(height: DashboardGrid.levelHeight)
            Capsule().frame(width: 30, height: 8)
                .frame(width: DashboardGrid.valueWidth, alignment: .trailing)
            Capsule().frame(width: 30, height: 7)
                .frame(width: DashboardGrid.resetWidth, alignment: .trailing)
        }
        .skeleton()
        .frame(height: DashboardGrid.rowHeight)
    }
}

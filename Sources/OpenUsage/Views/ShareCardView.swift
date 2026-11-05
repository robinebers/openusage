import SwiftUI

/// It sets its own width, opaque tray background (an `ImageRenderer` has no window backdrop) and forced
/// appearance.
struct ShareCardView: View {
    let family: DashboardFamily
    var plans: [String: String] = [:]
    let appearance: ColorScheme

    static let width: CGFloat = 360
    static let inset: CGFloat = 16

    var body: some View {
        ShareCardFrame(appearance: appearance) {
            DashboardProviderSection(family: family.hidingEmails) { account in
                DashboardAccountRows(account: account, plan: plans[account.id], hasSiblingAccounts: family.accounts.count > 1)
            }
        }
    }
}

/// A window's usage as a picture: the provider above the same detail its row shows on hover.
struct UsageBreakdownShareCard: View {
    let provider: Provider
    let breakdown: UsageBreakdown
    var figure = ModelFigure.cost
    let appearance: ColorScheme

    var body: some View {
        ShareCardFrame(appearance: appearance) {
            VStack(alignment: .leading, spacing: DashboardGrid.headerGap) {
                HStack(spacing: 0) {
                    Text(provider.displayName)
                        .font(DashboardGrid.headerFont)
                        .lineLimit(1)
                    Spacer(minLength: DashboardGrid.columnGap)
                    ProviderIcon(id: provider.icon, side: DashboardGrid.iconSize, inset: 0.04)
                }
                .padding(.horizontal, DashboardGrid.cardPadding)
                .frame(height: DashboardGrid.headerHeight)
                UsageBreakdownContent(breakdown: breakdown, provider: provider, figure: figure)
                    .padding(DashboardGrid.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
            }
        }
    }
}

/// The Priority tab as a picture, with the panel's title in place of its tabs.
struct PriorityShareCard: View {
    let board: PriorityBoard
    let now: Date
    let appearance: ColorScheme

    var body: some View {
        ShareCardFrame(appearance: appearance) {
            PriorityBoardList(board: board, now: now)
        }
    }
}

private struct ShareCardFrame<Content: View>: View {
    let appearance: ColorScheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(ShareCardView.inset)
            watermarkFooter
        }
        .frame(width: ShareCardView.width, alignment: .topLeading)
        .background(Theme.panelBody)
        .environment(\.drawsLevelsAsShapes, true)
        .environment(\.colorScheme, appearance)
    }

    private var watermarkFooter: some View {
        HStack(spacing: 6) {
            Image(nsImage: ProviderMarks.image(for: "openusage", side: 16, inset: 0))
                .renderingMode(.template)
            Text("OpenUsage")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Text("Your AI Limits at a Glance")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, ShareCardView.inset)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(Theme.cardFill)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
    }
}

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
        VStack(alignment: .leading, spacing: 12) {
            content
            watermarkFooter
        }
        .padding(ShareCardView.inset)
        .frame(width: ShareCardView.width, alignment: .topLeading)
        .background(Theme.shareCanvas)
        .environment(\.colorScheme, appearance)
    }

    private var watermarkFooter: some View {
        HStack(spacing: 6) {
            ProviderIcon(id: "openusage", side: 14, inset: 0)
            Text("Monitor Your AI Subscriptions with OpenUsage")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

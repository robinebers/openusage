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
        VStack(alignment: .leading, spacing: 12) {
            DashboardProviderSection(family: family.hidingEmails) { account in
                DashboardAccountRows(account: account, plan: plans[account.id])
            }
            watermarkFooter
        }
        .padding(Self.inset)
        .frame(width: Self.width, alignment: .topLeading)
        .background(Theme.traySurface)
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

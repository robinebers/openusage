import SwiftUI

/// The image "Share Screenshot" puts on the clipboard: one provider's header and card, with all its
/// accounts or one of them, as the dashboard draws them at rest — no popover, the logo leading — on the
/// panel's background, with the watermark footer, rasterized at ×4: the provider's header, each account
/// captioned over its rows. An account named by its email reads as its provider alone, so the email
/// never leaves the panel. The view takes already-resolved data, so it has no environment dependency
/// and renders the same way in the app and in tests.
///
/// It sets its own width, opaque tray background (an `ImageRenderer` has no window backdrop), forced
/// appearance, and tooltip suppression (the tooltips' AppKit anchors rasterize as yellow boxes otherwise).
struct ShareCardView: View {
    let family: DashboardFamily
    /// The plan of an account, by its id.
    var plans: [String: String] = [:]
    let appearance: ColorScheme

    /// Authored card width in points. The renderer multiplies this by `ShareCardRenderer.scale` for the
    /// PNG's pixel width; the height is whatever the rows add up to (flexible).
    static let width: CGFloat = 360
    /// The padding around the card, on every side.
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
        .environment(\.hoverTooltipsDisabled, true)
    }

    /// The brand mark + tagline, centered at the bottom. Quiet (secondary) so it reads as a watermark.
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

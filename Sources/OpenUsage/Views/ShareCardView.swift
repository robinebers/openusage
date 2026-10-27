import SwiftUI

/// The image "Share Screenshot" puts on the clipboard: one provider's header and card, with all its
/// accounts or one of them, as the dashboard draws them at rest — no popover, the logo leading — on the
/// panel's background, with the watermark footer, rasterized at ×4: the provider's header, each account
/// captioned over its rows. An account named by its email reads as its provider alone, so the email
/// never leaves the panel. The view takes already-resolved data, so it has no environment dependency
/// and renders the same way in the app and in tests.
struct ShareCardView: View {
    let family: DashboardFamily
    /// The plan of an account, by its id.
    var plans: [String: String] = [:]
    let appearance: ColorScheme

    /// Authored card width in points. The renderer multiplies this by `ShareCardRenderer.scale` for the
    /// PNG's pixel width; the height is whatever the rows add up to (flexible).
    static let width: CGFloat = 360
    /// The chrome's padding around the card, on every side.
    static let inset: CGFloat = 16

    var body: some View {
        let shown = family.hidingEmails
        ShareCardChrome(appearance: appearance) {
            DashboardProviderSection(family: shown) { account in
                DashboardAccountRows(account: account, plan: plans[account.id])
            }
        }
    }
}

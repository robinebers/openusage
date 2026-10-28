import AppKit
import SwiftUI

/// Renders a `ShareCardView` into a PNG and copies it to the clipboard: `ImageRenderer` → `cgImage`
/// (×4 for a crisp, large export) → PNG, written to the pasteboard.
@MainActor
enum ShareCardRenderer {
    /// Off-screen render scale. ×4 turns the popover-scale card into a crisp, large PNG — a 360pt card
    /// ships as a 1440px image — without authoring a separate large-format layout.
    static let scale: CGFloat = 4

    /// The card as PNG data, or `nil` if `ImageRenderer` produces no CGImage. Its point size is the
    /// card's natural (flexible) size and its pixel size that times `scale`, so the PNG records the
    /// matching resolution.
    static func png<Card: View>(for view: Card) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }

    /// The one "Share Screenshot": a picture of this card — a provider's accounts from its header's
    /// right-click, one account from its caption's — drawn as the dashboard draws them, copied to the
    /// clipboard. On a successful copy it asks the layout store to surface the transient "Copied to
    /// clipboard" pill; a failure beeps and logs instead.
    @discardableResult
    static func share(
        family: DashboardFamily,
        plans: [String: String],
        layout: LayoutStore,
        appearance: ColorScheme
    ) -> Bool {
        guard let png = png(for: ShareCardView(family: family, plans: plans, appearance: appearance)) else {
            AppLog.error(.lifecycle, "share card: failed to render a PNG for \(family.id)")
            NSSound.beep()
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else {
            AppLog.error(.lifecycle, "share card: pasteboard rejected the PNG")
            NSSound.beep()
            return false
        }
        layout.presentShareConfirmation()
        return true
    }
}

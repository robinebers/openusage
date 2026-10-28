import AppKit
import SwiftUI

@MainActor
enum ShareCardRenderer {
    static let scale: CGFloat = 4

    static func png<Card: View>(for view: Card) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }

    @discardableResult
    static func share(
        family: DashboardFamily,
        plans: [String: String],
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
        return true
    }
}

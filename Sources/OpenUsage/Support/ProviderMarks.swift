import AppKit
import SwiftUI

struct ProviderIcon: View {
    let id: String
    let side: CGFloat
    var inset: CGFloat = 0.14

    var body: some View {
        Image(nsImage: ProviderMarks.image(for: id, side: side, inset: inset))
            .renderingMode(.template)
            .foregroundStyle(Theme.iconGray)
    }
}

/// An account's provider mark. An account mirrored from a CLIProxyAPI hub carries the hub's mark in
/// the bottom-trailing corner, cut out of the provider's mark so the two never touch.
struct AccountIcon: View {
    let provider: Provider
    let side: CGFloat
    var inset: CGFloat = 0.14

    var body: some View {
        if provider.hubHost == nil {
            ProviderIcon(id: provider.icon, side: side, inset: inset)
        } else {
            let badge = side * 0.52
            let offset = side * 0.08
            ProviderIcon(id: provider.icon, side: side, inset: inset)
                .mask {
                    Rectangle()
                        .overlay(alignment: .bottomTrailing) {
                            Circle()
                                .frame(width: badge * 1.24, height: badge * 1.24)
                                .offset(x: offset + badge * 0.12, y: offset + badge * 0.12)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .overlay(alignment: .bottomTrailing) {
                    ProviderIcon(id: CLIProxyHub.markID, side: badge, inset: 0)
                        .offset(x: offset, y: offset)
                }
                .accessibilityLabel("Managed by CLIProxyAPI")
        }
    }
}

struct ProviderMark {
    let rep: NSImageRep
    let bounds: CGRect

    init?(contentsOf url: URL) {
        guard let rep = NSImage(contentsOf: url)?.representations.first, rep.size.width > 0, rep.size.height > 0 else { return nil }
        let pixels = 1024
        guard
            let raster = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: raster)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = raster.cgImage, let box = MenuBarStripRenderer.visibleBounds(of: cgImage) else { return nil }
        let unit = CGSize(width: rep.size.width / CGFloat(pixels), height: rep.size.height / CGFloat(pixels))
        self.rep = rep
        self.bounds = CGRect(
            x: box.minX * unit.width,
            y: (CGFloat(pixels) - box.maxY) * unit.height,
            width: box.width * unit.width,
            height: box.height * unit.height
        )
    }

    func fitted(side: CGFloat, inset: CGFloat) -> NSImage {
        let fitted = NSImage(size: NSSize(width: side, height: side), flipped: false) { square in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let target = square.insetBy(dx: square.width * inset, dy: square.height * inset)
            let scale = min(target.width / bounds.width, target.height / bounds.height)
            context.saveGState()
            context.translateBy(x: target.midX - bounds.midX * scale, y: target.midY - bounds.midY * scale)
            context.scaleBy(x: scale, y: scale)
            rep.draw(in: NSRect(origin: .zero, size: rep.size))
            context.restoreGState()
            return true
        }
        fitted.isTemplate = true
        return fitted
    }
}

@MainActor
enum ProviderMarks {
    private static var marks: [String: ProviderMark] = [:]
    private static var images: [String: NSImage] = [:]

    static func mark(for id: String) -> ProviderMark {
        if let cached = marks[id] { return cached }
        guard
            let url = Bundle.openUsageResources.url(forResource: id, withExtension: "svg", subdirectory: "ProviderIcons"),
            let mark = ProviderMark(contentsOf: url)
        else { preconditionFailure("The bundled mark \(id).svg failed to load") }
        marks[id] = mark
        return mark
    }

    static func image(for id: String, side: CGFloat, inset: CGFloat) -> NSImage {
        let key = "\(id)@\(side)@\(inset)"
        if let cached = images[key] { return cached }
        let image = mark(for: id).fitted(side: side, inset: inset)
        images[key] = image
        return image
    }
}

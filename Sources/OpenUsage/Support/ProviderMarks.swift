import AppKit
import SwiftUI

/// Draws a provider mark in monochrome (`Theme.iconGray`): on the glass popover, icon color
/// reads as noise (WWDC25 — monochrome reduces it), and provider identity comes from the name
/// beside the mark.
struct ProviderIcon: View {
    /// The mark's provider id (`ProviderKind.rawValue`), which names its SVG in `ProviderIcons/`.
    let id: String
    /// Side length of the square the mark is drawn in.
    let side: CGFloat
    /// Fraction of the side kept as margin all round. The default is the breathing room of list
    /// contexts (e.g. Settings); a mark that should fill its box, like the section header matching
    /// the menu-bar strip glyph, passes less.
    var inset: CGFloat = 0.14

    var body: some View {
        Image(nsImage: ProviderMarks.image(for: id, side: side, inset: inset))
            .renderingMode(.template)
            .foregroundStyle(Theme.iconGray)
    }
}

/// A provider's SVG as AppKit loads it, with the box its artwork covers.
///
/// The source SVGs disagree about whitespace: Claude, Codex and Cursor sit about 10% inside their
/// viewBox while Grok runs edge to edge. Fitting the artwork's own box gives every mark the same
/// optical weight, and one shared `inset` then adds the same breathing room to each.
struct ProviderMark {
    let rep: NSImageRep
    /// The artwork's bounds in the SVG's own points, found by rasterizing it once.
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

    /// A template image of `side` points with the artwork fitted and centered, `inset` of the side
    /// kept as margin all round. The handler draws the SVG under a transform, so AppKit and SwiftUI
    /// get vector output at whatever scale they draw the image.
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

/// The bundled provider marks, each loaded once, with a fitted template image cached per size and inset.
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

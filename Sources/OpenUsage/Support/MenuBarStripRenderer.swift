import AppKit
import SwiftUI

/// Renders the Text-style menu-bar strip (`MenuBarContent`) into a template `NSImage` for the
/// `MenuBarExtra` label: provider mark + bare value for a single metric, or a tight labeled stack for
/// two. Black-on-clear so macOS tints it for light/dark; sized to its natural width. A stale strip draws at
/// half strength, which the tint keeps. The image is built
/// outside the `label:` view builder (an `ImageRenderer` inline there throws obscure errors).
@MainActor
enum MenuBarStripRenderer {
    /// The pinned-metrics strip, or `nil` when nothing is pinned or no pinned metric has data yet
    /// (caller falls back to the app icon).
    ///
    /// The render is trimmed to its visible pixels: the view's anti-aliasing padding and the provider
    /// glyph's normalization inset would otherwise ship as transparent margins, widening the status
    /// item past its artwork (the menu bar already pads every item, so baked-in margins read as an
    /// extra-large gap next to neighboring items).
    static func image(for content: MenuBarContent) -> NSImage? {
        guard !content.isEmpty else { return nil }
        let renderer = ImageRenderer(content: MenuBarTextStrip(content: content))
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / renderer.scale, height: CGFloat(cgImage.height) / renderer.scale)
        )
        image.isTemplate = true
        image.accessibilityDescription = content.accessibilityText
        return image
    }

    /// The app icon the status item shows when the strip is empty, dimmed like a stale strip.
    static func appIcon(for content: MenuBarContent) -> NSImage {
        // The brand mark's smaller inset fills the menu-bar slot about as fully as a system glyph.
        let icon = ProviderMarks.image(for: "openusage", side: 18, inset: 0.08)
        guard content.isStale else { return icon }
        let dimmed = NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.5)
            return true
        }
        dimmed.isTemplate = true
        return dimmed
    }

    /// Crops fully transparent margins off a rendered strip, or `nil` when the image has no visible
    /// pixels (caller keeps the untrimmed render).
    nonisolated static func trimmedToVisibleContent(_ image: CGImage) -> CGImage? {
        guard let bounds = visibleBounds(of: image) else { return nil }
        return image.cropping(to: bounds)
    }

    /// The bounding box of pixels with non-zero alpha, in pixel coordinates (origin at the top-left
    /// row, matching `CGImage.cropping(to:)`), or `nil` for a fully transparent image.
    nonisolated static func visibleBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &alpha, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

private struct MenuBarTextStrip: View {
    let content: MenuBarContent

    var body: some View {
        HStack(spacing: 11) {
            ForEach(content.groups, id: \.provider.id) { group in
                HStack(spacing: 4) {
                    glyph(group.provider.icon)
                        .overlay(alignment: .bottomTrailing) {
                            if let badge = group.badge {
                                badgeView(badge)
                                    .offset(x: Self.badgeOverhang.width, y: Self.badgeOverhang.height)
                            }
                        }
                        .compositingGroup()
                        // The renderer draws only inside layout bounds, so reserve the badge's overhang
                        // (vertically on both sides, keeping the mark centred on its values) or it is cut off.
                        .padding(.trailing, group.badge == nil ? 0 : Self.badgeOverhang.width)
                        .padding(.vertical, group.badge == nil ? 0 : Self.badgeOverhang.height)
                    metricsView(group.metrics)
                }
            }
        }
        .foregroundStyle(.black)
        .monospacedDigit()
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
        .compositingGroup()
        .opacity(content.isStale ? 0.5 : 1)
    }

    /// A provider's pinned values, no labels: one metric as a single large number, two stacked on two
    /// tight lines (much narrower than side-by-side), read positionally.
    @ViewBuilder
    private func metricsView(_ metrics: [MenuBarContent.Metric]) -> some View {
        if metrics.count <= 1 {
            Text(metrics.first?.value ?? "")
                .font(.system(size: 12, weight: .bold))
        } else {
            VStack(alignment: .trailing, spacing: -2) {
                ForEach(metrics, id: \.id) { metric in
                    Text(metric.value)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .fixedSize()
        }
    }

    /// Side length of the glyph box. Sized to fill the strip's height so the mark reads at the same
    /// scale as the dual-line metric block beside it (the single number is shorter), instead of
    /// floating small in the middle. `ProviderMarks` fits every mark to its artwork's own bounds,
    /// so a near-zero `inset` here makes each provider fill this box uniformly.
    private static let glyphSide: CGFloat = 16

    /// How far an account badge reaches past the mark's bottom-trailing corner.
    private static let badgeOverhang = CGSize(width: 5, height: 2.5)

    /// The account tag on the mark's corner: a filled pill with the letters knocked out, ringed by a
    /// knocked-out gap so it reads against the mark beneath it. All black-on-clear, so the template
    /// tint keeps working in light and dark menu bars.
    private func badgeView(_ badge: String) -> some View {
        let label = Text(badge)
            .font(.system(size: 6.5, weight: .heavy))
            .padding(.horizontal, 2)
            .frame(minWidth: 8, minHeight: 8)
        return ZStack {
            Capsule().fill(Color.black)
                .padding(-1.25)
                .blendMode(.destinationOut)
            Capsule().fill(Color.black)
            label.foregroundStyle(Color.black).blendMode(.destinationOut)
        }
        .fixedSize()
    }

    private func glyph(_ icon: String) -> some View {
        Image(nsImage: ProviderMarks.image(for: icon, side: Self.glyphSide, inset: 0.04))
            .renderingMode(.template)
            .foregroundStyle(Color.black)
    }
}

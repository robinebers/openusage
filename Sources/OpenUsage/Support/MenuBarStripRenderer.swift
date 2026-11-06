import AppKit
import SwiftUI

@MainActor
enum MenuBarStripRenderer {
    static func image(for content: MenuBarContent) -> NSImage? {
        guard !content.isEmpty else { return content.updateAvailable ? appIconWithUpdateDot : nil }
        let (view, isTemplate) = stripView(for: content)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / renderer.scale, height: CGFloat(cgImage.height) / renderer.scale)
        )
        image.isTemplate = isTemplate
        image.accessibilityDescription = content.accessibilityText
        return image
    }

    private static func stripView(for content: MenuBarContent) -> (AnyView, Bool) {
        switch content.style {
        case .text:
            return (AnyView(MenuBarTextStrip(content: content)), true)
        case .bars:
            return (AnyView(MenuBarBarsStrip(content: content)), true)
        case .gauge:
            return (AnyView(MenuBarGaugeStrip(content: content, isColor: false)), true)
        case .colorGauge:
            return (AnyView(MenuBarGaugeStrip(content: content, isColor: true)), false)
        }
    }

    static var appIcon: NSImage {
        ProviderMarks.image(for: "openusage", side: 18, inset: 0.08)
    }

    /// The app icon at the same size with a dot in its top-right corner, cut out of the mark so the two
    /// never touch.
    static var appIconWithUpdateDot: NSImage {
        let icon = appIcon
        let image = NSImage(size: icon.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            icon.draw(in: rect)
            let dot = CGRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)
            context.setBlendMode(.clear)
            context.fillEllipse(in: dot.insetBy(dx: -1, dy: -1))
            context.setBlendMode(.normal)
            context.setFillColor(.black)
            context.fillEllipse(in: dot)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Update available"
        return image
    }

    nonisolated static func trimmedToVisibleContent(_ image: CGImage) -> CGImage? {
        guard let bounds = visibleBounds(of: image) else { return nil }
        return image.cropping(to: bounds)
    }

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

// MARK: - Common Components

private struct MenuBarOverflowBadge: View {
    let count: Int

    var body: some View {
        Text("+\(count)")
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(Capsule().fill(Color.black.opacity(0.16)))
    }
}

// MARK: - Text Strip

private struct MenuBarTextStrip: View {
    let content: MenuBarContent

    var body: some View {
        HStack(spacing: 11) {
            ForEach(content.items) { item in
                HStack(spacing: 4) {
                    glyph(item.provider.icon)
                        .overlay(alignment: .bottomTrailing) {
                            if let badge = item.provider.badge {
                                AccountBadge(text: badge)
                                    .offset(x: AccountBadge.overhang.width, y: AccountBadge.overhang.height)
                            }
                        }
                        .compositingGroup()
                        .padding(.trailing, item.provider.badge == nil ? 0 : AccountBadge.overhang.width)
                        .padding(.vertical, item.provider.badge == nil ? 0 : AccountBadge.overhang.height)
                    labelledValue(item)
                }
            }
            if content.overflow > 0 {
                MenuBarOverflowBadge(count: content.overflow)
            }
            if content.updateAvailable {
                Image(nsImage: MenuBarStripRenderer.appIconWithUpdateDot)
                    .renderingMode(.template)
            }
        }
        .foregroundStyle(.black)
        .monospacedDigit()
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
        .compositingGroup()
    }

    private func labelledValue(_ item: MenuBarContent.Item) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(item.shortLabel)
                .font(.system(size: 9, weight: .medium))
            Text(item.value)
                .font(.system(size: 11, weight: .bold))
        }
        .fixedSize()
    }



    private static let glyphSide: CGFloat = 16

    private func glyph(_ icon: String) -> some View {
        Image(nsImage: ProviderMarks.image(for: icon, side: Self.glyphSide, inset: 0.04))
            .renderingMode(.template)
            .foregroundStyle(Color.black)
    }
}

// MARK: - Bars Strip

private struct MenuBarBarsStrip: View {
    let content: MenuBarContent

    var body: some View {
        HStack(spacing: 6) {
            MenuBarBars(fractions: content.bars, side: 18)
            if content.overflow > 0 {
                MenuBarOverflowBadge(count: content.overflow)
            }
            if content.updateAvailable {
                Image(nsImage: MenuBarStripRenderer.appIconWithUpdateDot)
                    .renderingMode(.template)
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
        .compositingGroup()
    }


}

private struct MenuBarBars: View {
    let fractions: [Double]
    let side: CGFloat

    var body: some View {
        Canvas { context, size in
            draw(into: &context, size: size)
        }
        .frame(width: side, height: side)
    }

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        let n = max(1, min(4, fractions.count))
        let pad = max(1, (size.width * 0.08).rounded())
        let gap = max(1, (size.width * 0.03).rounded())
        let trackX = pad
        let trackW = size.width - 2 * pad

        let layoutN = CGFloat(max(2, n))
        let trackH = max(1, ((size.height - 2 * pad - (layoutN - 1) * gap) / layoutN).rounded(.down))
        let rx = max(1, (trackH / 3).rounded(.down))

        let totalBarsHeight = CGFloat(n) * trackH + CGFloat(n - 1) * gap
        let yOffset = pad + ((size.height - 2 * pad - totalBarsHeight) / 2).rounded(.down)

        for i in 0..<n {
            let y = yOffset + CGFloat(i) * (trackH + gap) + 1

            context.fill(
                bar(x: trackX, y: y, w: trackW, h: trackH, leading: rx, trailing: rx),
                with: .color(.black.opacity(0.16))
            )

            let fill = MenuBarBarGeometry.fill(trackW: trackW, fraction: i < fractions.count ? fractions[i] : 0)
            if fill.fillW > 0 {
                let trailing = fill.fillW >= trackW ? rx : max(0, (rx * 0.35).rounded(.down))
                context.fill(
                    bar(x: trackX, y: y, w: fill.fillW, h: trackH, leading: rx, trailing: trailing),
                    with: .color(.black)
                )
            }
            if fill.fillW > 0, fill.remainderW > 0, let dividerX = fill.dividerX {
                context.fill(
                    bar(x: trackX + dividerX, y: y, w: fill.remainderW, h: trackH,
                        leading: max(0, (rx * 0.2).rounded(.down)), trailing: rx),
                    with: .color(.black.opacity(0.24))
                )
            }
        }
    }

    private func bar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, leading: CGFloat, trailing: CGFloat) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: leading,
            bottomLeadingRadius: leading,
            bottomTrailingRadius: trailing,
            topTrailingRadius: trailing
        )
        .path(in: CGRect(x: x, y: y, width: w, height: h))
    }
}

enum MenuBarBarGeometry {
    struct Fill: Equatable {
        let fillW: CGFloat
        let remainderW: CGFloat
        let dividerX: CGFloat?
    }

    static func visualFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        let clamped = min(1, max(0, fraction))
        if clamped > 0.7, clamped < 1 {
            let remainder = 1 - clamped
            let quantized = min(1, (remainder / 0.15).rounded(.up) * 0.15)
            return max(0, 1 - quantized)
        }
        return clamped
    }

    static func fill(trackW: CGFloat, fraction: Double) -> Fill {
        guard fraction.isFinite, fraction > 0 else { return Fill(fillW: 0, remainderW: 0, dividerX: nil) }
        let visual = visualFraction(fraction)
        if visual >= 1 { return Fill(fillW: trackW, remainderW: 0, dividerX: nil) }
        let minVisible = max(4, (trackW * 0.2).rounded())
        let maxFillW = max(1, trackW - minVisible)
        let fillW = max(1, min(maxFillW, (trackW * CGFloat(visual)).rounded()))
        let trueRemainder = trackW - fillW
        let remainderW = min(trackW - 1, max(trueRemainder, minVisible))
        return Fill(fillW: fillW, remainderW: remainderW, dividerX: trackW - remainderW)
    }
}

// MARK: - Gauge Strip

private struct MenuBarGaugeStrip: View {
    let content: MenuBarContent
    let isColor: Bool

    var body: some View {
        HStack(spacing: 7) {
            ForEach(content.gauges) { gauge in
                MenuBarGaugeView(item: gauge, isColor: isColor)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge = gauge.provider.badge {
                            AccountBadge(text: badge)
                                .offset(x: AccountBadge.overhang.width, y: AccountBadge.overhang.height)
                        }
                    }
                    .compositingGroup()
                    .padding(.trailing, gauge.provider.badge == nil ? 0 : AccountBadge.overhang.width)
                    .padding(.vertical, gauge.provider.badge == nil ? 0 : AccountBadge.overhang.height)
            }
            if content.overflow > 0 {
                MenuBarOverflowBadge(count: content.overflow)
            }
            if content.updateAvailable {
                Image(nsImage: MenuBarStripRenderer.appIconWithUpdateDot)
                    .renderingMode(.template)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
        .compositingGroup()
    }


}

struct MenuBarGaugeGeometry {
    // Gap between top and bottom arcs on each side (45° for clear separation)
    static let gapDeg: Double = 45

    // Upper 1/3 arc: centered at top (-90°), span 80° (-130° to -50°)
    static let topStartDeg: Double = -130
    static let topSpanDeg: Double = 80

    // Lower 2/3 arc: centered at bottom (90°), span 190° (-5° to 185°)
    static let bottomStartDeg: Double = -5
    static let bottomEndDeg: Double = 185
    static let bottomSpanDeg: Double = 190

    static func arcPath(center: CGPoint, radius: CGFloat, startDeg: Double, endDeg: Double) -> Path {
        var path = Path()
        guard endDeg > startDeg else { return path }
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(startDeg),
            endAngle: .degrees(endDeg),
            clockwise: false
        )
        return path
    }

    static func paceTickPath(center: CGPoint, radius: CGFloat, angleDeg: Double, tickLength: CGFloat = 3.5) -> Path {
        let rad = angleDeg * .pi / 180
        let cosA = CGFloat(cos(rad))
        let sinA = CGFloat(sin(rad))
        let innerR = radius - tickLength / 2
        let outerR = radius + tickLength / 2
        var path = Path()
        path.move(to: CGPoint(x: center.x + innerR * cosA, y: center.y + innerR * sinA))
        path.addLine(to: CGPoint(x: center.x + outerR * cosA, y: center.y + outerR * sinA))
        return path
    }
}

struct MenuBarGaugeView: View {
    let item: MenuBarGaugeItem
    let isColor: Bool

    private static let side: CGFloat = 18
    private static let lineWidth: CGFloat = 2.5
    private static let iconSide: CGFloat = 9.5

    var body: some View {
        ZStack {
            Canvas { context, size in
                draw(into: &context, size: size)
            }
            .frame(width: Self.side, height: Self.side)

            Image(nsImage: ProviderMarks.image(for: item.provider.icon, side: Self.iconSide, inset: 0.04))
                .renderingMode(.template)
                .foregroundStyle(isColor ? Color.white : Color.black)
        }
        .frame(width: Self.side, height: Self.side)
    }

    private func gaugeColor(_ severity: WidgetData.MeterSeverity) -> Color {
        guard isColor else { return Color.black }
        switch severity {
        case .critical: return Color(red: 1.0, green: 0.28, blue: 0.28)
        case .warning: return Color(red: 1.0, green: 0.65, blue: 0.15)
        case .normal: return Color(red: 0.25, green: 0.68, blue: 1.0)
        }
    }

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = (min(size.width, size.height) - Self.lineWidth) / 2
        let trackStroke = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
        let fillStroke = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)

        // 1. Tracks (background arcs): clearly visible grey matching the empty portion of the menu bar bars
        let trackColor: Color = isColor
            ? Color.white.opacity(0.40)
            : Color.black.opacity(0.38)

        // Top track: -135° to -45°
        let topTrack = MenuBarGaugeGeometry.arcPath(
            center: center,
            radius: radius,
            startDeg: MenuBarGaugeGeometry.topStartDeg,
            endDeg: MenuBarGaugeGeometry.topStartDeg + MenuBarGaugeGeometry.topSpanDeg
        )
        context.stroke(topTrack, with: .color(trackColor), style: trackStroke)

        // Bottom track: -15° to 195°
        let bottomTrack = MenuBarGaugeGeometry.arcPath(
            center: center,
            radius: radius,
            startDeg: MenuBarGaugeGeometry.bottomStartDeg,
            endDeg: MenuBarGaugeGeometry.bottomEndDeg
        )
        context.stroke(bottomTrack, with: .color(trackColor), style: trackStroke)

        // 2. Fills (foreground usage arcs)
        // Top fill: fills left-to-right (-135° to -45°), so it decreases from the right
        let topFraction = min(max(item.topFraction, 0), 1)
        if topFraction > 0 {
            let topFillColor = gaugeColor(item.topSeverity)
            let topFill = MenuBarGaugeGeometry.arcPath(
                center: center,
                radius: radius,
                startDeg: MenuBarGaugeGeometry.topStartDeg,
                endDeg: MenuBarGaugeGeometry.topStartDeg + MenuBarGaugeGeometry.topSpanDeg * topFraction
            )
            context.stroke(topFill, with: .color(topFillColor), style: fillStroke)
        }

        // Bottom fill: fills towards right (-15°), so it decreases from the right towards left (195°)
        let bottomFraction = min(max(item.bottomFraction, 0), 1)
        if bottomFraction > 0 {
            let bottomFillColor = gaugeColor(item.bottomSeverity)
            let bottomFill = MenuBarGaugeGeometry.arcPath(
                center: center,
                radius: radius,
                startDeg: MenuBarGaugeGeometry.bottomEndDeg - MenuBarGaugeGeometry.bottomSpanDeg * bottomFraction,
                endDeg: MenuBarGaugeGeometry.bottomEndDeg
            )
            context.stroke(bottomFill, with: .color(bottomFillColor), style: fillStroke)
        }

        // 3. Pace guidelines (tick marks)
        let tickStroke = StrokeStyle(lineWidth: 1.4, lineCap: .round)
        let tickColor: Color = isColor
            ? Color.white.opacity(0.90)
            : Color.black.opacity(0.65)

        if let topPace = item.topPaceMark {
            let clamped = min(max(topPace, 0), 1)
            let angle = MenuBarGaugeGeometry.topStartDeg + clamped * MenuBarGaugeGeometry.topSpanDeg
            let tick = MenuBarGaugeGeometry.paceTickPath(center: center, radius: radius, angleDeg: angle, tickLength: 3.5)
            context.stroke(tick, with: .color(tickColor), style: tickStroke)
        }

        if let bottomPace = item.bottomPaceMark {
            let clamped = min(max(bottomPace, 0), 1)
            let angle = MenuBarGaugeGeometry.bottomEndDeg - clamped * MenuBarGaugeGeometry.bottomSpanDeg
            let tick = MenuBarGaugeGeometry.paceTickPath(center: center, radius: radius, angleDeg: angle, tickLength: 3.5)
            context.stroke(tick, with: .color(tickColor), style: tickStroke)
        }
    }
}

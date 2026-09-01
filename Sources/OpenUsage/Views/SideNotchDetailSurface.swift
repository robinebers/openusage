import SwiftUI

/// Keeps one detail card alive while the hovered provider changes. Every provider is measured at its
/// intrinsic height so the surface can retarget smoothly while its contents crossfade inside it.
struct SideNotchDetailSurface: View {
    let group: SideNotchContent.Group
    let groups: [SideNotchContent.Group]
    let centerOffset: CGFloat
    let trailingInset: CGFloat
    let fill: (WidgetData.MeterSeverity?) -> AnyShapeStyle
    let reduceMotion: Bool

    @State private var measuredHeights: [String: CGFloat] = [:]
    @State private var cardHeight: CGFloat?

    private let cardWidth = SideNotchLayout.detailCardWidth
    private let pointerWidth = SideNotchLayout.detailPointerWidth
    private let sectionSpacing = 13 * SideNotchLayout.scale
    private let contentFade = Animation.easeOut(duration: 0.18)
    private let frameMotion = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.24)

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                cardContent(for: group)
                    .id(group.id)
                    .transition(
                        reduceMotion
                            ? .identity
                            : .opacity.animation(contentFade)
                    )
            }
            .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
            .clipped()
            .background {
                RoundedRectangle(cornerRadius: 21 * SideNotchLayout.scale, style: .continuous)
                    .fill(.black)
            }
            .background {
                measurementLayer
            }

            SideNotchPointer()
                .fill(.black)
                .frame(
                    width: pointerWidth,
                    height: 34 * SideNotchLayout.scale
                )
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.trailing, trailingInset)
        .offset(y: centerOffset)
        .animation(
            reduceMotion ? nil : frameMotion,
            value: centerOffset
        )
        .onChange(of: group.id) { _, providerID in
            guard let height = measuredHeights[providerID] else { return }
            setCardHeight(height, animated: true)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }

    private var measurementLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(groups) { candidate in
                cardContent(for: candidate)
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        record(height: height, for: candidate.id)
                    }
            }
        }
        .allowsHitTesting(false)
    }

    private func record(height: CGFloat, for providerID: String) {
        guard height > 0 else { return }
        let previousHeight = measuredHeights[providerID]
        guard previousHeight == nil || abs(previousHeight! - height) > 0.5 else { return }

        measuredHeights[providerID] = height
        guard providerID == group.id else { return }
        setCardHeight(height, animated: cardHeight != nil)
    }

    private func setCardHeight(_ height: CGFloat, animated: Bool) {
        guard cardHeight == nil || abs(cardHeight! - height) > 0.5 else { return }
        guard animated, !reduceMotion else {
            cardHeight = height
            return
        }

        withAnimation(frameMotion) {
            cardHeight = height
        }
    }

    private func cardContent(for group: SideNotchContent.Group) -> some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            HStack(spacing: 9 * SideNotchLayout.scale) {
                ProviderIcon(source: group.icon, inset: 0.08)
                    .frame(
                        width: 21 * SideNotchLayout.scale,
                        height: 21 * SideNotchLayout.scale
                    )
                Text("\(group.displayName) Usage")
                    .font(.system(size: 17 * SideNotchLayout.scale, weight: .bold))
                    .lineLimit(1)
            }

            ForEach(group.metrics) { metric in
                VStack(alignment: .leading, spacing: 7 * SideNotchLayout.scale) {
                    HStack(alignment: .firstTextBaseline, spacing: 8 * SideNotchLayout.scale) {
                        Text(metric.label)
                            .font(.system(size: 13 * SideNotchLayout.scale, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8 * SideNotchLayout.scale)
                        if let resetText = metric.resetText {
                            Text(resetText)
                                .font(.system(size: 12 * SideNotchLayout.scale))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if metric.isBounded {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.18))
                                Capsule()
                                    .fill(fill(metric.severity))
                                    .frame(width: geometry.size.width * min(max(metric.fraction, 0), 1))
                            }
                        }
                        .frame(height: 4 * SideNotchLayout.scale)
                    }

                    Text(metric.usedHeadline)
                        .font(.system(size: 13 * SideNotchLayout.scale, weight: .semibold))
                        .monospacedDigit()
                }
            }

            if let reset = group.availableReset {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(height: 1 * SideNotchLayout.scale)

                    VStack(alignment: .leading, spacing: 4 * SideNotchLayout.scale) {
                        HStack(spacing: 6 * SideNotchLayout.scale) {
                            Circle()
                                .fill(fill(reset.severity))
                                .frame(
                                    width: 6 * SideNotchLayout.scale,
                                    height: 6 * SideNotchLayout.scale
                                )
                            Text(reset.count == 1 ? "1 Available Reset" : "\(reset.count) Available Resets")
                                .font(.system(size: 12 * SideNotchLayout.scale, weight: .semibold))
                                .lineLimit(1)
                        }
                        Text(
                            "Expires \(Formatters.monthDayLabel(reset.expiresAt)) at "
                                + TimeFormatSetting.current.shortTime(reset.expiresAt)
                        )
                        .font(.system(size: 11 * SideNotchLayout.scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            }
        }
        .padding(16 * SideNotchLayout.scale)
        .frame(width: cardWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SideNotchPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

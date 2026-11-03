import AppKit
import SwiftUI

/// A page of the panel, which scrolls under the bars `panelBars` sets above and below it.
struct PopoverScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }
}

extension View {
    /// Sets `top` and `bottom` over a scrolling page of the panel. Content scrolls cleanly under the
    /// top bar, which hides it. Content under the bottom bar blurs behind it: from macOS 26 with the
    /// system's soft scroll edge effect, before it with frosted glass. Nothing is drawn behind the bottom
    /// bar while nothing is under it.
    func panelBars(@ViewBuilder top: () -> some View, @ViewBuilder bottom: () -> some View) -> some View {
        modifier(PanelBars(top: top(), bottom: bottom()))
    }
}

private struct PanelBars<Top: View, Bottom: View>: ViewModifier {
    /// How far content must be under the bottom bar to frost it fully.
    private static var fullFrost: CGFloat { 12 }

    let top: Top
    let bottom: Bottom
    @State private var underBottom: CGFloat = 0

    func body(content: Content) -> some View {
        let barred = content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let below = geometry.contentSize.height + geometry.contentInsets.bottom
                    - geometry.containerSize.height - geometry.contentOffset.y
                return min(max(below / Self.fullFrost, 0), 1)
            } action: { _, under in
                underBottom = under
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                top.background(Theme.panelBody)
            }
        if #available(macOS 26, *) {
            barred
                .safeAreaBar(edge: .bottom, spacing: 0) { bottom }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .scrollEdgeEffectHidden(true, for: underBottom > 0 ? .top : .vertical)
        } else {
            barred.safeAreaInset(edge: .bottom, spacing: 0) {
                bottom.background {
                    FooterFrost(opacity: underBottom)
                        .padding(.top, -FooterFrost.reach)
                }
            }
        }
    }
}

/// The frosted glass behind the bottom bar before macOS 26: an in-window blur of what is under it, in
/// the material whose tint comes closest to the panel's, washed halfway back to the panel's color so the
/// tint barely shows. It is full from the panel's edge to just short of the bar's top and fades out a
/// little above it.
private struct FooterFrost: NSViewRepresentable {
    /// How far the frost reaches above the bar into the page.
    static let reach: CGFloat = 10

    let opacity: CGFloat

    func makeNSView(context: Context) -> FrostView { FrostView() }

    func updateNSView(_ view: FrostView, context: Context) {
        view.alphaValue = opacity
    }

    final class FrostView: NSView {
        private let blur = NSVisualEffectView()
        private let wash = CALayer()
        private let fade = CAGradientLayer()

        init() {
            super.init(frame: .zero)
            blur.material = .menu
            blur.blendingMode = .withinWindow
            blur.state = .active
            addSubview(blur)
            wantsLayer = true
            wash.zPosition = 1
            layer?.addSublayer(wash)
            fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            fade.startPoint = CGPoint(x: 0.5, y: 0)
            fade.endPoint = CGPoint(x: 0.5, y: 1)
            layer?.mask = fade
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            blur.frame = bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fade.frame = bounds
            wash.frame = bounds
            effectiveAppearance.performAsCurrentDrawingAppearance {
                wash.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor
            }
            let fadeLength = FooterFrost.reach + 4
            fade.locations = [0, NSNumber(value: Double(max(bounds.height - fadeLength, 0) / max(bounds.height, 1))), 1]
            CATransaction.commit()
        }
    }
}

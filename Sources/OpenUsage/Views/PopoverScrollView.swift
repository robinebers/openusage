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
    /// Sets `top` and `bottom` over a scrolling page of the panel. Content scrolled under a bar blurs
    /// into frosted glass behind it, as under a window's title bar, and nothing is drawn behind a bar
    /// while nothing is under it. From macOS 26 this stands in for the system's scroll edge effect.
    func panelBars(@ViewBuilder top: () -> some View, @ViewBuilder bottom: () -> some View) -> some View {
        modifier(PanelBars(top: top(), bottom: bottom()))
    }
}

private struct PanelBars<Top: View, Bottom: View>: ViewModifier {
    let top: Top
    let bottom: Bottom
    @State private var scrolledUnder = ScrolledUnder()

    func body(content: Content) -> some View {
        let barred = content
            .onScrollGeometryChange(for: ScrolledUnder.self, of: ScrolledUnder.init) { _, under in
                scrolledUnder = under
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                top.background {
                    BarFrost(edge: .top, opacity: scrolledUnder.top)
                        .padding(.bottom, -BarFrost.reach)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottom.background {
                    BarFrost(edge: .bottom, opacity: scrolledUnder.bottom)
                        .padding(.top, -BarFrost.reach)
                }
            }
        if #available(macOS 26, *) {
            barred.scrollEdgeEffectHidden(true, for: .vertical)
        } else {
            barred
        }
    }
}

/// How much content is under each bar, from 0 for none to 1 for enough to frost the bar fully.
private struct ScrolledUnder: Equatable {
    private static let fullFrost: CGFloat = 12

    var top: CGFloat = 0
    var bottom: CGFloat = 0

    init() {}

    init(_ geometry: ScrollGeometry) {
        let above = geometry.contentOffset.y + geometry.contentInsets.top
        let below = geometry.contentSize.height + geometry.contentInsets.bottom
            - geometry.containerSize.height - geometry.contentOffset.y
        top = min(max(above / Self.fullFrost, 0), 1)
        bottom = min(max(below / Self.fullFrost, 0), 1)
    }
}

/// The frosted glass behind a bar: an in-window blur of what is under it, in the material whose tint
/// comes closest to the panel's, washed halfway back to the panel's color so the tint barely shows. It
/// is full from the panel's edge to just short of the bar's inner edge and fades out a little past it.
private struct BarFrost: NSViewRepresentable {
    /// How far the frost reaches past the bar into the page.
    static let reach: CGFloat = 10

    let edge: VerticalEdge
    let opacity: CGFloat

    func makeNSView(context: Context) -> FrostView { FrostView() }

    func updateNSView(_ view: FrostView, context: Context) {
        view.edge = edge
        view.alphaValue = opacity
    }

    final class FrostView: NSView {
        var edge = VerticalEdge.top {
            didSet { needsLayout = true }
        }

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
            fade.startPoint = CGPoint(x: 0.5, y: edge == .top ? 1 : 0)
            fade.endPoint = CGPoint(x: 0.5, y: edge == .top ? 0 : 1)
            let fadeLength = BarFrost.reach + 4
            fade.locations = [0, NSNumber(value: Double(max(bounds.height - fadeLength, 0) / max(bounds.height, 1))), 1]
            CATransaction.commit()
        }
    }
}

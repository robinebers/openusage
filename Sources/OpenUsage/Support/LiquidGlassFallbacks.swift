import SwiftUI

extension View {
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }

    /// A single interactive Liquid Glass surface (in the given shape) drawn behind a *whole control* —
    /// the footer's Options menu button wraps its plain-styled label in one
    /// `interactiveGlass(in: Capsule())` so it sits on one continuous capsule. Apply it to the
    /// container, and keep the control `.buttonStyle(.plain)` so this modifier owns the surface — the
    /// system `.buttonStyle(.glass)` renders flat on a `Menu` (its own button chrome wins), and per-segment
    /// glass would split the capsule. `.interactive()` adds the hover/press shimmer + scale that reads
    /// as Liquid Glass. macOS 15 gets the frosted material shape with a hairline border (no glass there).
    func interactiveGlass<Shape: InsettableShape>(in shape: Shape) -> some View {
        modifier(MotionAwareInteractiveGlassModifier(shape: shape))
    }

    @ViewBuilder
    func barGlass() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: Rectangle())
        } else {
            background(.bar)
        }
    }

    @ViewBuilder
    func pinnedBar<Bar: View>(_ edge: VerticalEdge, spacing: CGFloat, @ViewBuilder content: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, spacing: spacing, content: content)
        }
    }

    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            self
        }
    }
}

private struct MotionAwareInteractiveGlassModifier<Shape: InsettableShape>: ViewModifier {
    let shape: Shape
    @Environment(\.reduceAnimations) private var reduceAnimations

    /// Liquid Glass owns its hover/press scale and shimmer outside the view's normal transaction. Swap
    /// only that interactive variant for static system glass under Reduce Motion.
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if reduceAnimations {
                content.glassEffect(.regular, in: shape)
            } else {
                content.glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
        }
    }
}

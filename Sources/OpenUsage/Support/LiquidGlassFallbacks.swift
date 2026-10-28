import SwiftUI

/// Availability-gated wrappers for the handful of macOS 26 (Tahoe) Liquid Glass APIs the popover
/// uses, so the rest of the UI can call them declaratively and the app still builds and runs on
/// macOS 15 (Sequoia).
///
/// These are purely cosmetic fallbacks — they swap Liquid Glass styling for the established
/// pre-Tahoe controls (`.bordered` button styles, `.safeAreaInset`, no scroll-edge blur). Function
/// is preserved on every supported OS: the footer still pins, the buttons keep their active/inactive
/// distinction, the scroll view still scrolls. Nothing here hides a runtime error — each branch is a
/// compile-time `#available` check, which is the intended way to back-deploy newer-SDK APIs.
///
/// These gate purely on OS version. The popover backdrop is opaque (the panel's tray background,
/// matching `Theme.traySurface`), and glass stays reserved for the footer chrome — its `.bar`/glass bar
/// plus the interactive glass controls — never the content cards.
///
/// Keeping every `#available(macOS 26, *)` check in this one file means the views (`PopoverFooter`,
/// `SettingsScreen`, `DashboardView`) stay free of inline availability branches.
extension View {
    /// Liquid Glass button style on macOS 26, the matching bordered style on macOS 15.
    ///
    /// `.glass`/`.glassProminent` and `.bordered`/`.borderedProminent` are distinct
    /// `PrimitiveButtonStyle` types, so this branches the whole `.buttonStyle(...)` call through a
    /// `@ViewBuilder` rather than a ternary (which would not type-check).
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

    /// Liquid Glass surface for a full chrome bar (the footer / top bar) on macOS 26+, a frosted
    /// material on macOS 15. `glassEffect` is the content-aware Liquid Glass: it lenses the in-app
    /// content scrolling beneath the bar (and stays consistent regardless of what's behind the window),
    /// which reads as real glass — verified rendering in the NSPanel-hosted popover on the macOS 27
    /// (Golden Gate) beta. (A behind-window `NSVisualEffectView` is an alternative if `glassEffect` ever
    /// regresses, but it samples the *desktop* rather than the app's own content; see git history.)
    @ViewBuilder
    func barGlass() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: Rectangle())
        } else {
            background(.bar)
        }
    }

    /// Pins a bar to the top (the Accounts / Settings back nav bar) or bottom (the footer) of scrolling
    /// content. On macOS 26 this uses `safeAreaBar`, which also feeds the native scroll-edge blur as
    /// content passes under it; on macOS 15 it uses `safeAreaInset` (macOS 12+), which pins the bar
    /// identically but without the blur.
    @ViewBuilder
    func pinnedBar<Bar: View>(_ edge: VerticalEdge, spacing: CGFloat, @ViewBuilder content: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, spacing: spacing, content: content)
        }
    }

    /// Applies the soft scroll-edge effect to both edges on macOS 26 — the subtle blurred fade of
    /// content passing under the pinned bars (Apple's `.soft` `ScrollEdgeEffectStyle`, vs the
    /// `.hard`/default "linear, nearly opaque" bar); no custom gradient or material bar. On macOS 15
    /// there's no equivalent, so it's a no-op — the bars still pin via `safeAreaInset`, content just
    /// scrolls flush to them.
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

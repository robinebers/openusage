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
/// These gate purely on OS version. The popover surface itself is always opaque — `PopoverSurface`
/// paints `Theme.traySurface` with opaque grouped cards over it — and Liquid Glass is reserved for
/// the footer's chrome controls here, rendered over that solid backing (the normal in-window look).
///
/// Keeping every `#available(macOS 26, *)` check in this one file means the views (`HeaderView`,
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
    /// the footer's split button wraps its `HStack` (Customize + divider + chevron) in one
    /// `interactiveGlass(in: Capsule())` so the two plain-styled tap targets sit on one continuous
    /// capsule rather than two separate pills. Apply it to the container, never to each segment, and
    /// keep the segments `.buttonStyle(.plain)` so this glass is the only surface — the system
    /// `.buttonStyle(.glass)` renders flat on a `Menu` (its own button chrome wins), and per-segment
    /// glass would split the capsule. `.interactive()` adds the hover/press shimmer + scale that reads
    /// as Liquid Glass. macOS 15 gets a frosted material shape with a hairline border (no glass there).
    @ViewBuilder
    func interactiveGlass(in shape: some InsettableShape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
        }
    }

    /// Pins a bottom bar below scrolling content. On macOS 26 this uses `safeAreaBar`, which also
    /// feeds the native scroll-edge blur as content passes under it; on macOS 15 it uses
    /// `safeAreaInset` (macOS 12+), which pins the bar identically but without the blur.
    @ViewBuilder
    func pinnedFooter<Footer: View>(spacing: CGFloat, @ViewBuilder content: () -> Footer) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: spacing, content: content)
        }
    }

    /// Pins a bar above scrolling content (the Customize / Settings back nav bar). On macOS 26 this
    /// uses `safeAreaBar`, which also feeds the native scroll-edge blur as content passes under it; on
    /// macOS 15 it uses `safeAreaInset` (macOS 12+), which pins the bar identically but without the blur.
    @ViewBuilder
    func pinnedTopBar<Bar: View>(spacing: CGFloat, @ViewBuilder content: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .top, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: spacing, content: content)
        }
    }

    /// Applies the soft top scroll-edge effect on macOS 26. On macOS 15 there is no equivalent, so
    /// this is a no-op — the scroll view still scrolls and clips correctly, it just loses the blur.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

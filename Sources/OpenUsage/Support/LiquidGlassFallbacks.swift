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
/// These gate purely on OS version — the Reduce Transparency setting deliberately does *not* drop
/// the glass controls (that downgraded the macOS 26 look to the macOS 15 one). Reduce Transparency
/// instead makes the *surface* opaque (`PopoverSurface`) and frosts the cards (`Theme.cardSurface`),
/// so the glass buttons stay glass — just rendered over a solid backing, which is the normal
/// in-window look.
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

    /// Groups adjacent glass buttons in a `GlassEffectContainer` on macOS 26 so the system samples
    /// their glass coherently. On macOS 15 there is no glass to coordinate, so the container is
    /// dropped and the content is returned unchanged.
    @ViewBuilder
    func glassButtonGroup(spacing: CGFloat) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
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

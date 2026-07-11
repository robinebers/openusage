import CoreGraphics
import Observation

/// The popover's auto-fit height *computation*, split out of `DashboardView`: per-screen measured
/// pieces summed into each screen's ideal window height (the morph target), clamped to the panel's
/// allowed range. The view keeps the animation itself — `animatedHeight`, the screen-switch slide, and
/// the `withAnimation` spring — so this holds only the deterministic measurement/target logic (which is
/// now unit-testable), not the timing-sensitive animation clock.
///
/// Held as `@State` by the view; `@Observable` so `measuredIdeal` changes drive the view's morph
/// `onChange`. The measured parts are written from the view's geometry callbacks via the setters.
@MainActor
@Observable
final class PanelHeightCoordinator {
    /// The window height each screen wants (top bar + footer + scroll content) — the morph target the
    /// view animates toward. `private(set)`: written only through the measurement setters below.
    private(set) var measuredIdeal: [PopoverScreen: CGFloat] = [:]

    @ObservationIgnored private var measuredScrollContent: [PopoverScreen: CGFloat] = [:]
    @ObservationIgnored private var measuredFooter: [PopoverScreen: CGFloat] = [:]
    @ObservationIgnored private let topBarHeight: CGFloat

    init(topBarHeight: CGFloat) {
        self.topBarHeight = topBarHeight
    }

    /// Record a screen's measured scroll-content height (from the view's geometry action) and recompose
    /// its ideal.
    func setScrollContent(_ height: CGFloat, for screen: PopoverScreen) {
        measuredScrollContent[screen] = height
        recomposeIdeal(for: screen)
    }

    /// Record a screen's measured footer height (Dashboard and Settings have different content) and
    /// recompose.
    func setFooter(_ height: CGFloat, for screen: PopoverScreen) {
        measuredFooter[screen] = height
        recomposeIdeal(for: screen)
    }

    /// Sum a screen's measured parts into its ideal window height. The dashboard shows no top bar; other
    /// screens pin it to `topBarHeight`. A zero/absent scroll content leaves the ideal unset (not yet
    /// measured), so the view keeps the size the controller opened at until a real measurement lands.
    private func recomposeIdeal(for screen: PopoverScreen) {
        guard let content = measuredScrollContent[screen], content > 0 else { return }
        let topBar: CGFloat = screen == .dashboard ? 0 : topBarHeight
        let footer = measuredFooter[screen] ?? 0
        measuredIdeal[screen] = topBar + footer + content
    }

    /// The clamped target height for a screen, or `nil` until it's been measured.
    func target(for screen: PopoverScreen) -> CGFloat? {
        measuredIdeal[screen].map(clamped)
    }

    /// Clamp an ideal to the panel's [min, screen-max] via the shared hook (identity when unset).
    private func clamped(_ ideal: CGFloat) -> CGFloat {
        MenuBarPopover.clampHeight?(ideal) ?? ideal
    }
}

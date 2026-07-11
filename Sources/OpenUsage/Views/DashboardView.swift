import SwiftUI

/// The popover content: the provider/metric list (or the Customize / Settings screen) as a scroll
/// view between fixed chrome — a top back/title bar on Customize/Settings and bottom identity/action
/// chrome on Dashboard and Settings. Customize uses its top bar and scrolling content without footer
/// controls.
///
/// The chrome is fixed: it's keyed off `layout.screen` and applied uniformly in `screenView`, so on a
/// screen switch only the content slides while the footer and top bar stay put. Each screen's scroll
/// content underlaps the footer with the native soft scroll-edge fade (`softBottomScrollEdge` →
/// `.scrollEdgeEffectStyle(.soft)`, macOS 26+) — Apple's blurred boundary, not a custom gradient or a
/// material bar. On macOS 15 the footer/top bar still pin via `safeAreaInset`, just without the blur
/// (content scrolls flush). The panel **auto-fits its content**: each screen publishes its intrinsic
/// height (`ScrollContentHeightKey` + the measured footer), and the host window is driven to that on
/// SwiftUI's animation clock (`drivesPanelHeight` / `PanelHeightModifier`) — so a screen switch morphs
/// the window height in lockstep with the slide (one spring), and the scroll views only take over once
/// content exceeds the screen-height cap.
struct DashboardView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(PopoverTransparencyStore.self) private var transparency
    @Environment(UpdaterController.self) private var updater
    @State private var reorderLift: ReorderLift?
    /// The panel height SwiftUI drives — the single animation clock. `PanelHeightModifier` follows it
    /// frame-by-frame onto the AppKit panel, so the window resize rides the same spring as the screen
    /// slide (no second AppKit animation to fight). 0 means "not established yet": the panel keeps the
    /// size the controller opened it at until the first measurement lands, then we snap un-animated.
    @State private var animatedHeight: CGFloat = 0
    /// Whether `animatedHeight` has been seeded for this open. Until then the first measurement (or a
    /// reopen) establishes it without animation; afterwards, changes spring.
    @State private var didEstablishHeight = false
    /// Popover auto-fit height computation: per-screen measured pieces summed into each screen's clamped
    /// morph target (`heightCoordinator.measuredIdeal` / `.target(for:)`). Written from the geometry
    /// actions below. The animation itself — `animatedHeight`, the slide, the `withAnimation` spring —
    /// stays in this view; the coordinator holds only the deterministic measurement.
    @State private var heightCoordinator = PanelHeightCoordinator(topBarHeight: Self.topBarHeight)
    /// Horizontal screen-switch slide: 0 shows the outgoing screen, 1 the incoming one. Drives the
    /// page offset so the screens slide between modes on one spring.
    @State private var slideProgress: CGFloat = 1
    /// The `layout.screenSlideID` whose slide has begun animating. Until it catches up to the store's
    /// id, a freshly-started transition pins to the outgoing screen so the first frame never flashes
    /// the destination.
    @State private var animatedSlideID = 0
    /// Reset to the top whenever the popover closes, so it never reopens mid-scroll.
    @State private var dashboardScrollPosition = ScrollPosition(edge: .top)
    /// Drives the macOS-native confirmation sheet for the Customize "reset all" button. The alert
    /// attaches to this panel as a sheet (see `StatusItemController`'s attached-sheet guard), so a
    /// click on its buttons can't be misread as an outside click that dismisses the popover.
    @State private var isPresentingResetAllConfirm = false
    /// Shared horizontal inset for dashboard content and fixed chrome.
    private static let outerPadding: CGFloat = 14
    /// Breathing room between the bottom of the scrolling content and the pinned footer. Kept small
    /// because the native scroll edge effect — not whitespace — provides the visual separation.
    private static let contentBottomGap: CGFloat = 12
    /// Footer content starts at the same standard padding as the provider containers.
    private static let footerHorizontalPadding: CGFloat = outerPadding
    private static let reorderSpace = "popoverReorderSpace"
    /// One width across both densities — switching density shouldn't move the popover's left edge.
    private static let popoverWidth: CGFloat = 320
    /// Fixed height of the Customize / Settings back nav bar — the bar pins itself to exactly this height.
    private static let topBarHeight: CGFloat = 44

    var body: some View {
        modeBody
            .frame(width: Self.popoverWidth)
            // Fill the panel. The panel auto-fits its content (the window height is driven to each
            // screen's measured ideal via `drivesPanelHeight`), so at rest the window is exactly the
            // content's height and this fill is a no-op; when content exceeds the screen cap the window
            // clamps and the scroll views inside take the overflow.
            .frame(maxHeight: .infinity, alignment: .top)
            // Paint the page surface behind all content (and the footer). Opaque by default so the
            // popover reads as one solid panel; under Increase Transparency / the egg it clears so the
            // behind-window backdrop (or party gradient) shows through. Outermost so the footer, header,
            // and scroll content all sit on it; separation from the footer comes from the native soft
            // scroll-edge fade (not a distinct bar).
            .background(PopoverSurface())
            // Drive the host panel's height on SwiftUI's clock. At the body root, OUTSIDE `modeBody`'s
            // `.animation(nil, value: layout.screenSlideID)`, so the height rides the active spring (the
            // slide's, during a switch) instead of being snapped.
            .drivesPanelHeight(animatedHeight)
            .overlay(alignment: .topLeading) {
                if let reorderLift {
                    ReorderLiftPreview(lift: reorderLift)
                }
            }
            .coordinateSpace(name: Self.reorderSpace)
            .background(
                // Esc backs out of Customize / Settings first; only from the dashboard does it close
                // the popover. Return opens Customize from the dashboard (the same affordance the
                // footer's Options ▸ Customize menu item carries) and returns to the
                // dashboard from Customize or Settings — matching Esc and the back navigation,
                // never jumping Settings → Customize. Always consumed, so a bare Return can't fall
                // through and dismiss the popover.
                PopoverKeyReader(
                    onEscape: {
                        // From a provider's L2 detail, back out to the L1 list first; only from L1 /
                        // Settings drop to the dashboard. Pressing Esc again from L1 closes the popover.
                        if layout.customizeProviderID != nil {
                            withAnimation(Motion.spring) { layout.customizeProviderID = nil }
                            return true
                        }
                        guard layout.screen != .dashboard else { return false }
                        withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
                        return true
                    },
                    onReturn: {
                        // From a provider's L2 detail, back out to the L1 list first — matching Esc —
                        // so Return steps L2 → L1 → dashboard instead of jumping L2 → dashboard.
                        if layout.customizeProviderID != nil {
                            withAnimation(Motion.spring) { layout.customizeProviderID = nil }
                            return true
                        }
                        let target: PopoverScreen = layout.screen == .dashboard ? .customize : .dashboard
                        withAnimation(Motion.modeSwitch) { layout.screen = target }
                        return true
                    },
                    // ⌘, toggles Settings, on this always-on monitor so it fires from every screen —
                    // including Settings, whose footer has no Settings action. Handling it here (and
                    // consuming it) also lets the Options menu's Settings item carry ⌘, as a label
                    // without a second SwiftUI registration fighting it.
                    onSettings: {
                        withAnimation(Motion.modeSwitch) {
                            layout.screen = layout.screen == .settings ? .dashboard : .settings
                        }
                        return true
                    },
                    // ⌘Z walks back the last customization step (remove/add, reorder, pin/unpin, caret
                    // move) — app-wide, since Hide and Pin happen via the dashboard's context menus too,
                    // not only in Customize. Always consumed here: by the time the monitor calls this it
                    // has already confirmed the panel owns the keystroke and no text field is editing
                    // (those keep their own ⌘Z), so returning false would only let AppKit beep on an empty
                    // undo. With nothing to undo we swallow it silently instead.
                    onUndo: {
                        guard layout.canUndo else { return true }
                        withAnimation(Motion.spring) { _ = layout.undo() }
                        return true
                    }
                )
            )
            // The controller already owns the exact show/hide moments. Reuse that signal here instead
            // of asking AppKit window notifications to rediscover the same state a second time.
            .onChange(of: transparency.popoverShown) { _, shown in
                if shown {
                    // Reopen: the SwiftUI tree survives a close, so re-seed the height for whatever
                    // screen we're opening on. Un-animated, and ≈ the controller's opening guess, so
                    // there's no visible jump. If not yet measured, the measurement onChange seeds it.
                    if let target = heightCoordinator.target(for: layout.screen) {
                        didEstablishHeight = true
                        animatedHeight = target
                    }
                } else {
                    resetTransientState()
                }
            }
            // A screen switch can tear the list down mid-drag, in which case the gesture's
            // `onEnded` never fires — clear the lift here or its overlay survives onto the new
            // screen.
            .onChange(of: layout.screen) {
                reorderLift = nil
                layout.cancelDrag()
            }
            // The Reset All alert attaches to the Customize L1 nav bar. Leaving the list — back to the
            // dashboard or into a provider's L2 detail — unmounts that host, which dismisses the alert
            // but leaves `isPresentingResetAllConfirm` `true`. Drop it whenever L1 stops being visible
            // so the destructive confirmation can't reappear stale on return without a fresh tap.
            .onChange(of: layout.screen == .customize && layout.customizeProviderID == nil) { _, isL1Visible in
                if !isL1Visible { isPresentingResetAllConfirm = false }
            }
            // Each screen switch: pin to the outgoing screen for one render (`slideProgress = 0`),
            // then spring to the incoming one on the next runloop tick. Deferring the animation one
            // tick is what makes it animate — setting 0 then 1 in the same closure collapses to a
            // no-op (SwiftUI animates from the last *committed* value). `slideProgress` drives the
            // page offset so the screens slide between modes on one spring.
            .onChange(of: layout.screenSlideID) { _, id in
                guard id != 0 else { return }
                slideProgress = 0
                animatedSlideID = id
                let destination = layout.screen
                Task { @MainActor in
                    // Co-animate the slide and the height on ONE spring → the coordinated morph: the
                    // panel grows/shrinks to the destination's size as that screen slides in. The
                    // destination is usually mounted+measured by now (it mounted on the slideProgress=0
                    // render), so we morph to its ideal. If it ISN'T measured yet and the height was
                    // never established (animatedHeight still the 0 sentinel — e.g. opening Settings
                    // straight from the status-item menu), we must NOT morph to a clamped zero, which
                    // floors to minPanelHeight and wrongly shrinks the panel: leave the height alone and
                    // let the completion / measurement establish it once a real ideal lands.
                    let coTarget: CGFloat? = heightCoordinator.target(for: destination)
                        ?? (animatedHeight > 0 ? animatedHeight : nil)
                    if coTarget != nil { didEstablishHeight = true }
                    withAnimation(Motion.spring, completionCriteria: .logicallyComplete) {
                        slideProgress = 1
                        if let coTarget { animatedHeight = coTarget }
                    } completion: {
                        guard let target = heightCoordinator.target(for: layout.screen) else { return }
                        if !didEstablishHeight {
                            didEstablishHeight = true
                            animatedHeight = target            // un-animated establish — never grow from 0
                        } else if abs(target - animatedHeight) > 1 {
                            withAnimation(Motion.spring) { animatedHeight = target }
                        }
                    }
                }
            }
            // In-screen growth/shrink (a provider card expands, the footer notice appears, a refresh
            // loads rows): re-target the height on the same spring. Establishment is allowed even mid-
            // slide (a measurement that lands during a switch must seed the height — there's nothing to
            // fight yet); the animated *re-target* defers to the switch path while a slide is in flight.
            .onChange(of: heightCoordinator.measuredIdeal[layout.screen]) { _, _ in
                guard let target = heightCoordinator.target(for: layout.screen) else { return }
                if !didEstablishHeight {
                    didEstablishHeight = true
                    animatedHeight = target
                } else if !isSliding, abs(target - animatedHeight) > 1 {
                    withAnimation(Motion.spring) { animatedHeight = target }
                }
            }
            // Watches for the secret transparency code while the panel is key and toggles the egg. A
            // sibling of `PopoverKeyReader` that only observes (never consumes), so it can't disturb
            // navigation or typing.
            .background(TooMuchTransparencyKeyReader { transparency.toggleSecretCode() })
            // Reaches `modeBody`, the `PopoverSurface` background, and every card: drives whether surfaces
            // paint their opaque base or clear to the behind-window vibrancy backdrop.
            .environment(\.popoverSurfaceTreatment, transparency.surfaceTreatment)
            // The easter egg's visuals: the readable party (gradient backdrop + glowing rim, text crisp
            // on frosted cards) for the secret code, or the woozy, barely-readable pink-glass drunk mode
            // for "Drunk Mode". No-op for the normal/increased styles. Controls stay clickable (overlays
            // don't hit-test), so the Settings "Drunk Mode" toggle is reachable while it's running.
            .tooMuchTransparency(transparency.effectiveStyle)
            // Gate the egg's animation loops on whether the popover is on-screen. Applied OUTSIDE
            // `.tooMuchTransparency` so it reaches both the gradient/rim/drunk layers that modifier adds
            // and the in-content `partyPulse`. Hidden → the loops unmount their `TimelineView` clocks, so a
            // left-on egg spends no CPU; a fresh mount on reopen / in-place activation starts them at once.
            // Sourced from the controller's show/hide chokepoints (`popoverShown`), not occlusion — a
            // `.canJoinAllSpaces` panel is briefly occluded mid Space-switch while still on-screen.
            .environment(\.popoverIsVisible, transparency.popoverShown)
    }

    private func resetTransientState() {
        // Backstop for any popover-close path the status-item controller's hide doesn't cover: clear a
        // tooltip the cursor was resting on, since the closed popover fires no hover-exit. The Usage
        // Trend hover popover rides the same backstop.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        if layout.screen != .dashboard { layout.screen = .dashboard }
        reorderLift = nil
        layout.cancelDrag()
        // A "Copied to clipboard" pill mid-countdown would otherwise reappear stale on the next open,
        // since the layout store survives the popover and only the timer clears it.
        layout.clearShareConfirmation()
        layout.clearCustomizationNotice()
        // Dismiss a pending Reset All confirmation if the popover closes mid-alert — the SwiftUI tree
        // survives `orderOut`, so without this the sheet would reappear stale on the next open.
        isPresentingResetAllConfirm = false
        // Drop the driven height so the next open re-establishes it (un-animated) from the reopened
        // screen's measurement instead of springing from this session's last value. Until then the
        // 0 sentinel keeps `PanelHeightModifier` from pushing, so the controller's opening guess stands.
        animatedHeight = 0
        didEstablishHeight = false
        dashboardScrollPosition.scrollTo(edge: .top)
    }

    /// The popover's screens as a horizontal pager. At rest only the current screen is mounted (one
    /// page at offset 0), so drag-reorder's coordinate math and the footer's scroll-edge underlap are
    /// exactly what they'd be with the screen rendered alone. During a switch the outgoing and incoming
    /// screens are both mounted, ordered left-to-right by `slideRank`, and slid by a pure offset — while
    /// the chrome (top bar + footer), keyed off `layout.screen` in `screenView`, is identical on both
    /// pages, so it stays visually fixed while only the content slides beneath it.
    ///
    /// Why an offset and not a SwiftUI `.transition`: the cards' fill is translucent `.quaternary`
    /// glass. Any transition carrying `.opacity` composites a screen into a transparency layer where
    /// that material has no vibrant backdrop to sample and resolves to its opaque near-white base — a
    /// white flash across the grey cards (the regression this removes; it has no clean SwiftUI fix).
    /// A pure offset never touches opacity, so the glass keeps sampling the live popover backdrop. The
    /// pages are a `ForEach` keyed by screen, so the incoming page keeps its identity (and scroll
    /// position) when the slide collapses back to one page. `.animation(nil, value:)` stops the
    /// one-frame structural re-layout at the start of a switch from inheriting the footer buttons'
    /// mode-switch animation — only `slideProgress` animates the offset.
    private var modeBody: some View {
        let pages = slidePages
        return HStack(alignment: .top, spacing: 0) {
            ForEach(pages, id: \.self) { screen in
                screenView(screen)
                    .frame(width: Self.popoverWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: Self.popoverWidth, alignment: .leading)
        .offset(x: slideOffset(pages))
        .animation(nil, value: layout.screenSlideID)
    }

    /// True from the moment `layout.screen` changes until the slide reaches the incoming screen.
    private var isSliding: Bool {
        layout.screenSlideID != 0
            && (layout.screenSlideID != animatedSlideID || slideProgress < 1)
    }

    /// One page at rest (the current screen); the two involved screens in left-to-right rank order
    /// while a switch animates.
    private var slidePages: [PopoverScreen] {
        guard isSliding else { return [layout.screen] }
        let from = layout.screenSlideFrom
        let to = layout.screen
        return from.slideRank < to.slideRank ? [from, to] : [to, from]
    }

    /// Horizontal offset that places the outgoing screen at `slideProgress == 0` and the incoming one
    /// at `1`. Pinned to the outgoing screen until this transition's animation has actually started, so
    /// the first frame after a switch shows the screen being left — never a flash of the destination.
    private func slideOffset(_ pages: [PopoverScreen]) -> CGFloat {
        guard isSliding, pages.count > 1 else { return 0 }
        let fromOffset = -CGFloat(pages.firstIndex(of: layout.screenSlideFrom) ?? 0) * Self.popoverWidth
        let toOffset = -CGFloat(pages.firstIndex(of: layout.screen) ?? 0) * Self.popoverWidth
        let progress = animatedSlideID == layout.screenSlideID ? slideProgress : 0
        return fromOffset + progress * (toOffset - fromOffset)
    }

    /// Builds one screen: its scroll body wrapped in the fixed chrome. The chrome (top bar + footer)
    /// is keyed off `layout.screen` — the *destination* — not the per-page `screen`, so during a switch
    /// both mounted pages render identical chrome pinned to the
    /// same edges. The chrome therefore stays put while only the content offsets beneath it (the
    /// "one fixed footer / top bar doesn't slide" behaviour). The soft scroll-edge styles and the
    /// pinned bars attach to each page's scroll view (`PopoverScrollView`), the documented place for
    /// them. Identity stays stable across the slide via the `ForEach` key in `modeBody`.
    @ViewBuilder
    private func screenView(_ screen: PopoverScreen) -> some View {
        scrollBody(for: screen)
            // Auto-fit: the scroll content publishes its intrinsic height (invariant to the viewport),
            // which we sum with the chrome into this screen's ideal window height. Keyed by the per-page
            // `screen`, so during a slide each mounted page measures its own content.
            .onPreferenceChange(ScrollContentHeightKey.self) { height in
                heightCoordinator.setScrollContent(height, for: screen)
            }
            .softTopScrollEdge()
            .softBottomScrollEdge()
            .pinnedTopBar(spacing: 0) {
                PopoverTopBar(
                    layout: layout,
                    height: Self.topBarHeight,
                    horizontalPadding: Self.footerHorizontalPadding,
                    onResetAll: {
                        layout.resetToDefault()
                        container.reseedEnabledProviders()
                    },
                    isPresentingResetAllConfirm: $isPresentingResetAllConfirm
                )
            }
            .pinnedFooter(spacing: 0) {
                PopoverFooter(
                    screen: layout.screen,
                    layout: layout,
                    dataStore: dataStore,
                    horizontalPadding: Self.footerHorizontalPadding
                ) { screen, height in
                    heightCoordinator.setFooter(height, for: screen)
                }
            }
    }

    /// The scrolling content for a screen, without chrome — this is the part that slides during a
    /// switch (its `screen` is the per-page one, so each mounted page shows its own content).
    @ViewBuilder
    private func scrollBody(for screen: PopoverScreen) -> some View {
        switch screen {
        case .dashboard:
            DashboardContentView(
                container: container,
                layout: layout,
                updater: updater,
                reorderSpaceName: Self.reorderSpace,
                horizontalPadding: Self.outerPadding,
                bottomGap: Self.contentBottomGap,
                reorderLift: $reorderLift,
                scrollPosition: $dashboardScrollPosition
            )
        case .customize:
            CustomizeView(
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift
            )
        case .settings:
            SettingsScreen()
        }
    }

}

/// The popover's opaque backdrop tray, painted behind all content so the popover reads as one solid
/// panel — the data region never shows the desktop through it. Matches the AppKit panel backdrop
/// (`PopoverBackdropView`'s `NSBox`): SwiftUI uses `Theme.traySurface` here while AppKit uses the
/// matching `Theme.trayNSColor`. The footer draws its own frosted glass bar on top of this (in-window),
/// so glass stays chrome over solid content. Never hit-tests, so it can't steal clicks from the content
/// above it.
private struct PopoverSurface: View {
    @Environment(\.popoverSurfaceTreatment) private var treatment

    var body: some View {
        Group {
            switch treatment {
            case .opaque:
                Theme.traySurface
            case .translucent:
                // Clear so what's behind the page shows through: the behind-window vibrancy backdrop —
                // the blurred desktop for increased/drunk, and the same desktop tinted by the party
                // gradient for party mode.
                Color.clear
            }
        }
        .allowsHitTesting(false)
    }
}

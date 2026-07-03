import SwiftUI
import AppKit

/// The popover content: the provider/metric list (or the Customize / Settings screen) as a scroll
/// view between fixed chrome — a top back/title bar on Customize/Settings, and a single bottom footer
/// (app identity / Customize pin summary + the glass Customize/Settings buttons).
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
    @State private var didInitialRefresh = false
    @State private var reorderLift: ReorderLift?
    /// The panel height SwiftUI drives — the single animation clock. `PanelHeightModifier` follows it
    /// frame-by-frame onto the AppKit panel, so the window resize rides the same spring as the screen
    /// slide (no second AppKit animation to fight). 0 means "not established yet": the panel keeps the
    /// size the controller opened it at until the first measurement lands, then we snap un-animated.
    @State private var animatedHeight: CGFloat = 0
    /// Whether `animatedHeight` has been seeded for this open. Until then the first measurement (or a
    /// reopen) establishes it without animation; afterwards, changes spring.
    @State private var didEstablishHeight = false
    /// Per-screen intrinsic heights, summed into `measuredIdeal`. Written only from geometry/preference
    /// actions (which run after `body`), so they never trip "Modifying state during view update".
    @State private var measuredScrollContent: [PopoverScreen: CGFloat] = [:]
    @State private var measuredFooter: [PopoverScreen: CGFloat] = [:]
    /// The window height each screen wants — top bar + footer + scroll content. The morph target.
    @State private var measuredIdeal: [PopoverScreen: CGFloat] = [:]
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
    /// Row rhythm tracks the global density setting live.
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

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
            // scroll-edge fade (not a distinct bar). The resize handle is folded into the footer (see
            // `footerBar`), so there's no separate root-level dragger inset anymore.
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
                // dashboard from Customize or Settings — matching Esc and the prominent "Done" control,
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
                    // including Settings, which has no footer. Handling it here (and consuming it) is
                    // also what lets the More menu's Settings item carry ⌘, purely as a label without a
                    // second SwiftUI registration fighting it. (#717 made footers per-page and dropped
                    // the Settings footer, so the old footer-hosted shortcut button no longer fired
                    // there — ⌘, fell through to AppKit and defocused the panel.)
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
            .background(
                PopoverVisibilityReader { visible in
                    if visible {
                        // Reopen: the SwiftUI tree survives a close, so re-seed the height for whatever
                        // screen we're opening on. Un-animated, and ≈ the controller's opening guess, so
                        // there's no visible jump. If not yet measured, the measurement onChange seeds it.
                        if let target = targetHeight() {
                            didEstablishHeight = true
                            animatedHeight = target
                        }
                    } else {
                        resetTransientState()
                    }
                }
            )
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
                    // straight from the status-item menu), we must NOT morph to clampedTarget(0), which
                    // floors to minPanelHeight and wrongly shrinks the panel: leave the height alone and
                    // let the completion / measurement establish it once a real ideal lands.
                    let coTarget: CGFloat? = measuredIdeal[destination].map { clampedTarget($0) }
                        ?? (animatedHeight > 0 ? animatedHeight : nil)
                    if coTarget != nil { didEstablishHeight = true }
                    withAnimation(Motion.spring, completionCriteria: .logicallyComplete) {
                        slideProgress = 1
                        if let coTarget { animatedHeight = coTarget }
                    } completion: {
                        guard let target = targetHeight() else { return }
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
            .onChange(of: measuredIdeal[layout.screen]) { _, _ in
                guard let target = targetHeight() else { return }
                if !didEstablishHeight {
                    didEstablishHeight = true
                    animatedHeight = target
                } else if !isSliding, abs(target - animatedHeight) > 1 {
                    withAnimation(Motion.spring) { animatedHeight = target }
                }
            }
            .task {
                guard !didInitialRefresh else { return }
                didInitialRefresh = true
                await dataStore.refreshAll()
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
        TrendHoverState.dismissAll()
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

    /// Builds one screen: its scroll body wrapped in the fixed chrome. The chrome (top bar + footer
    /// with the folded-in resize handle) is keyed off `layout.screen` — the *destination* — not the
    /// per-page `screen`, so during a switch both mounted pages render identical chrome pinned to the
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
                measuredScrollContent[screen] = height
                recomposeIdeal(for: screen)
            }
            .softTopScrollEdge()
            .softBottomScrollEdge()
            .pinnedTopBar(spacing: 0) { fixedTopBar }
            .pinnedFooter(spacing: 0) { footerBar(for: layout.screen) }
    }

    // MARK: - Auto-fit height

    /// Sum a screen's measured parts into its ideal window height. Top bar is the fixed `topBarHeight`
    /// on Customize/Settings and 0 on the dashboard (it pins itself to that exact height); the footer is
    /// measured because it varies (the Customize pin summary, the denied-pin notice line).
    private func recomposeIdeal(for screen: PopoverScreen) {
        guard let content = measuredScrollContent[screen], content > 0 else { return }
        let topBar: CGFloat = screen == .dashboard ? 0 : Self.topBarHeight
        let footer = measuredFooter[screen] ?? 0
        measuredIdeal[screen] = topBar + footer + content
    }

    /// This screen's ideal height clamped to where the panel can actually sit (the controller owns the
    /// [min, screen-max] clamp); `nil` until the screen has been measured.
    private func targetHeight() -> CGFloat? {
        guard let ideal = measuredIdeal[layout.screen] else { return nil }
        return clampedTarget(ideal)
    }

    private func clampedTarget(_ ideal: CGFloat) -> CGFloat {
        MenuBarPopover.clampHeight?(ideal) ?? ideal
    }

    /// The scrolling content for a screen, without chrome — this is the part that slides during a
    /// switch (its `screen` is the per-page one, so each mounted page shows its own content).
    @ViewBuilder
    private func scrollBody(for screen: PopoverScreen) -> some View {
        switch screen {
        case .dashboard:
            scrollingDashboard
        case .customize:
            CustomizeView(
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift
            )
        case .settings:
            SettingsScreen()
        }
    }

    /// The fixed top back/title bar, keyed off `layout.screen` so it's identical on both slide pages
    /// (no horizontal travel): the back nav bar on Customize/Settings, nothing on the dashboard. The
    /// bar pins itself to `topBarHeight`; the dashboard shows nothing here.
    @ViewBuilder
    private var fixedTopBar: some View {
        switch layout.screen {
        case .dashboard:
            EmptyView()
        case .customize:
            // L2 (provider detail) shows a per-provider reset button; L1 (the list) carries the
            // "reset all customization" button in the same trailing slot. Title swaps to the provider
            // name on L2; back is context-aware (L2 → L1, L1 → dashboard).
            if let id = layout.customizeProviderID {
                navBar(title: customizeTitle, back: customizeBack) {
                    resetButton(for: id)
                }
            } else {
                navBar(title: customizeTitle, back: customizeBack) {
                    resetAllButton()
                }
                .alert("Reset All Customization?", isPresented: $isPresentingResetAllConfirm) {
                    Button("Reset All", role: .destructive) {
                        withAnimation(Motion.spring) { layout.resetToDefault() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Resets every provider, their metrics and the order. Are you sure?")
                }
            }
        case .settings:
            navBar(title: "Settings") {
                withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
            } trailing: {
                EmptyView()
            }
        }
    }

    /// The Customize top-bar title: the provider's name when its L2 detail is open, otherwise "Customize".
    private var customizeTitle: String {
        layout.customizeProviderID.flatMap { layout.provider(id: $0)?.displayName } ?? "Customize"
    }

    /// Customize's context-aware back: L2 → L1 (the slide), L1 → dashboard (the usual screen slide).
    private func customizeBack() {
        if layout.customizeProviderID != nil {
            withAnimation(Motion.spring) { layout.customizeProviderID = nil }
        } else {
            withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
        }
    }

    /// The widget list as a scroll view that fills the region the footer leaves. The content scrolls
    /// under the footer with the native soft scroll-edge fade (`softTopScrollEdge`/`softBottomScrollEdge`
    /// are applied uniformly in `screenView`). Unlike Customize/Settings it tracks the dashboard's own
    /// scroll position, so that modifier stays here on the scroll view.
    private var scrollingDashboard: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // A pending update found by a scheduled Sparkle check tops everything — it's the
                // reminder the buried Sparkle window can't deliver for a dockless app.
                if let updateVersion = updater.availableUpdateVersion {
                    UpdateBannerCard(version: updateVersion)
                        .padding(.bottom, density.sectionSpacing)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                // The one-time first-run hint sits above the provider sections (and above the
                // empty-state line, which a fresh install can hit while nothing has data yet).
                // It scrolls with the content — a grouped card, not chrome.
                if container.onboarding.isCustomizeHintPending {
                    CustomizeHintCard()
                        .padding(.bottom, density.sectionSpacing)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                widgetContent
            }
            .animation(Motion.spring, value: container.onboarding.isCustomizeHintPending)
            .animation(Motion.spring, value: updater.availableUpdateVersion)
            .padding(.horizontal, Self.outerPadding)
            .padding(.top, density.contentTopPadding)
            .padding(.bottom, Self.contentBottomGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($dashboardScrollPosition)
    }

    @ViewBuilder
    private var widgetContent: some View {
        if layout.displayGroups.isEmpty {
            Text("Turn on Customize to choose what to show.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
        } else {
            WidgetGroupedListView(
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift
            )
        }
    }

    // MARK: - Pinned top nav bar

    /// The back nav bar pinned above Customize and Settings — the macOS-native place for a back
    /// affordance (top-leading), replacing the old trailing footer "Done" button. It's fixed chrome:
    /// applied uniformly in `screenView` via `pinnedTopBar` and keyed off `layout.screen` (see
    /// `fixedTopBar`), so it doesn't slide with the pages — it appears in place when entering
    /// Customize/Settings and clears on the dashboard, while the content slides beneath it. Its
    /// `barGlass()` (Liquid Glass) background lenses the content scrolling under it — the same
    /// content-aware glass as the footer.
    private func navBar<Trailing: View>(title: String, back: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) -> some View {
        // Centered title with the back control floating leading and a trailing action — the macOS
        // toolbar convention (leading navigation · centered title · trailing actions). The title is
        // centered against the *full* bar width (a ZStack layer, not an HStack slot) so it stays
        // optically centered regardless of the leading/trailing control widths.
        ZStack {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                backButton(action: back)
                Spacer(minLength: 8)
                trailing()
            }
        }
        .padding(.horizontal, Self.footerHorizontalPadding)
        .frame(height: Self.topBarHeight)
        .frame(maxWidth: .infinity)
        // Same content-aware Liquid Glass as the footer (`barGlass`) — the matching top/bottom chrome.
        .barGlass()
    }

    /// The round glass back button (chevron leading), matching the footer's glass control idiom. Esc
    /// and the system shortcuts back out too; this is the visible, expected affordance. The action is
    /// supplied by the caller so Customize can back L2 → L1 before L1 → dashboard.
    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
                .frame(width: 16, height: 16)
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .hoverTooltip("Back")
        .accessibilityLabel("Back")
    }

    /// The trailing reset button on a provider's L2 detail — a circular glass control mirroring the
    /// leading back chevron. Resets just that provider's metrics, order, stars, and On Demand
    /// membership (`resetProvider`), leaving other providers and the provider order untouched. Only
    /// shown on L2; the L1 list has no trailing action.
    private func resetButton(for providerID: String) -> some View {
        Button {
            withAnimation(Motion.spring) { layout.resetProvider(providerID) }
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .hoverTooltip("Reset \(layout.provider(id: providerID)?.displayName ?? providerID)")
        .accessibilityLabel("Reset")
    }

    /// The trailing "reset all customization" button on the L1 Customize list — the all-providers
    /// counterpart to `resetButton`. Same circular glass idiom and reset icon; the scope (everything
    /// vs. one provider) is conveyed by the tooltip and the confirmation sheet it opens. The sheet
    /// (`isPresentingResetAllConfirm`) is a real macOS alert, so a destructive "Reset All" is a
    /// deliberate two-step action — never a single mis-click that wipes the whole layout.
    private func resetAllButton() -> some View {
        Button {
            isPresentingResetAllConfirm = true
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .hoverTooltip("Reset All Customization")
        .accessibilityLabel("Reset All Customization")
    }

    // MARK: - Pinned footer

    /// The bottom chrome as one unit: the footer row — app identity + live refresh countdown (or the
    /// Customize pin summary) plus the glass Customize/Settings buttons — with the resize handle folded
    /// directly beneath it. Pinned via `pinnedFooter` (`safeAreaBar` on macOS 26; `safeAreaInset` on
    /// macOS 15).
    ///
    /// Its background is `barGlass()` — content-aware Liquid Glass (`glassEffect`) that lenses the
    /// in-app data scrolling beneath it, so the footer reads as real glass over the content (and stays
    /// consistent regardless of what's behind the window; the body stays opaque). A custom `safeAreaBar`
    /// gets no automatic system glass on macOS 27, so this explicit background is REQUIRED — without it
    /// the footer is transparent and content bleeds through. On Settings the trailing buttons are empty
    /// (`HeaderView` only shows them on the dashboard), leaving just the identity line.
    @ViewBuilder
    private func footerBar(for screen: PopoverScreen) -> some View {
        Group {
            if screen == .customize {
                // No footer on Customize — the summary was retired with the old flat layout. A denied
                // star shakes in place (StarButton) instead of surfacing a footer notice here.
                EmptyView()
            } else {
                HStack(alignment: .center, spacing: 8) {
                    footerIdentity
                    Spacer(minLength: 8)
                    HeaderView(screen: screen)
                }
            }
        }
        .padding(.horizontal, Self.footerHorizontalPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        // Content-aware Liquid Glass: `glassEffect` lenses the in-app data scrolling under the footer
        // (not the desktop), so it stays consistent regardless of what's behind the window. Renders on
        // macOS 26+, including the macOS 27 (Golden Gate) beta; macOS 15 falls back to a frosted material.
        .barGlass()
        // The footer's height feeds the auto-fit sum (`recomposeIdeal`); it varies — the Customize
        // summary line vs the dashboard identity row vs the denied-pin notice — so measure it rather
        // than assume a constant. Keyed by the destination `screen` (footer is keyed off `layout.screen`).
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
            measuredFooter[screen] = height
            recomposeIdeal(for: screen)
        }
        // A successful "Share Screenshot" springs a small "Copied ✓" pill up just above the footer —
        // a floating success toast that's more glanceable than the in-footer text line, and separate
        // from it. Dashboard-only (share is a dashboard action). The pill re-identifies on the trigger
        // so back-to-back copies of the same provider each replay the pop-in.
        .overlay(alignment: .top) {
            if screen == .dashboard, layout.shareConfirmation {
                shareCopiedPill
                    // Float just above the footer's top edge with a small gap (the pill is ~28pt, so -34
                    // leaves ~6pt of clear space) — a toast over the bottom content, not covering the
                    // footer's own identity row / Settings button.
                    .offset(y: -34)
            }
        }
        .animation(Motion.spring, value: layout.shareConfirmation)
        .animation(Motion.spring, value: layout.shareConfirmationTrigger)
    }

    /// The floating "Copied to clipboard" pill that springs up just above the footer when a provider
    /// screenshot is copied — a small frosted capsule that reads as a transient success toast. `.id` on
    /// the trigger so a repeat copy of the same provider re-pops instead of sitting motionless.
    private var shareCopiedPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("Copied to clipboard")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Theme.positive)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .id(layout.shareConfirmationTrigger)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    /// Count of enabled ("active") metrics across providers — the "N active" half of the Customize footer
    /// summary. Pinned metrics are a subset of these.
    /// Leading side of the footer. Normal mode shows the app name with the live "Next update in …"
    /// line beneath it; Customize mode shows the pin count ("4 pinned") in the same slot.
    /// Settings keeps the normal identity — the version line doubles as the About info there.
    /// A denied pin attempt swaps either line for the reason (in orange), played with the macOS
    /// deny shake — the wrong-password idiom — on every blocked click.
    @ViewBuilder
    private var footerIdentity: some View {
        // Both lines share the same font and muted style so the footer reads as one block.
        VStack(alignment: .leading, spacing: 0) {
            Text("OpenUsage \(AppInfo.version)")
            if let notice = layout.pinLimitNotice {
                Text(notice)
                    .foregroundStyle(Theme.notice)
                    // This label is inserted by the denial itself, so it must shake on mount.
                    .denyShake(trigger: layout.pinNoticeShakeTrigger, shakeOnAppear: true)
            } else {
                nextUpdateButton
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .animation(Motion.spring, value: layout.pinLimitNotice)
    }

    /// Ticks once a second so the "Next update in …" copy counts down live, and doubles as the manual
    /// refresh control: clicking it (or ⌘R) forces a fresh pass immediately. While a refresh is in
    /// flight it reads "Updating…" with a small system spinner after the text.
    private var nextUpdateButton: some View {
        Button {
            refreshNow()
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    Text(updateStatusText(now: context.date))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if isUpdating {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .hoverTooltip("Refresh now (⌘R)")
        .disabled(isUpdating)
    }

    private func refreshNow() {
        guard !isUpdating else { return }
        Task { await dataStore.refreshAll(force: true) }
    }

    private var isUpdating: Bool {
        !dataStore.refreshingProviderIDs.isEmpty
    }

    /// "Updating…" during an in-flight refresh, otherwise a live countdown to the next scheduled pass
    /// (last completed pass + the refresh interval). Falls back to a full interval before the first pass.
    private func updateStatusText(now: Date) -> String {
        if isUpdating {
            return "Updating…"
        }
        let interval = RefreshSetting.interval
        let base = dataStore.lastRefreshAt ?? now
        let remaining = max(0, base.addingTimeInterval(interval).timeIntervalSince(now))
        let totalSeconds = Int(remaining.rounded(.up))
        if totalSeconds >= 60 {
            let minutes = Int((Double(totalSeconds) / 60).rounded(.up))
            return "Next update in \(minutes)m"
        }
        return "Next update in \(totalSeconds)s"
    }
}

/// The popover's opaque backdrop tray, painted behind all content so the popover reads as one solid
/// panel — the data region never shows the desktop through it. Matches the AppKit panel backdrop
/// (`StatusItemController`'s `NSBox`) — both `Theme.traySurface`. The footer draws its own frosted
/// glass bar on top of this (in-window), so glass stays chrome over solid content. Never hit-tests,
/// so it can't steal clicks from the content above it.
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

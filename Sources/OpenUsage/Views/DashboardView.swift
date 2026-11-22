import SwiftUI

struct DashboardView: View {
    /// Settings is expensive to mount because each menu picker creates an `NSPopUpButton`. Keep its
    /// view tree alive after the first visit so later screen switches don't rebuild those controls.
    @State private var hasVisitedSettings = false
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    @Environment(\.reduceAnimations) private var reduceAnimations
    @State private var reorderLift: ReorderLift?
    /// The height the panel is headed for. During a slide or page push it gets there with
    /// `slideProgress`, from `slideStartHeight`, so a late or corrected report only moves where the
    /// motion ends; otherwise the panel takes it in one step.
    @State private var animatedHeight: CGFloat = 0
    @State private var slideStartHeight: CGFloat = 0
    @State private var didEstablishHeight = false
    @State private var measuredIdeal = MeasuredPanelHeights()
    @State private var isOpening = false
    /// The `popover.screenSlideID` the panel opened on. A screen chosen while the panel was closed, like
    /// Settings from the status item's menu, slides as the panel opens and keeps the opening window.
    @State private var openingSlideID = 0
    @State private var slideProgress: CGFloat = 1
    @State private var animatedSlideID = 0
    /// The `popover.screenSlideID` whose slide has ended. Until the store's id lands here the pager keeps
    /// both screens mounted, so the outgoing one slides away with its chrome. `slideProgress` can't
    /// tell: its model value is 1 from the moment the spring starts, so a pager keyed on it would drop
    /// the outgoing screen on the slide's first frame and leave it fading in place over the incoming one.
    @State private var settledSlideID = 0
    @State private var dashboardScrollPosition = ScrollPosition(edge: .top)
    private static let reorderSpace = "popoverReorderSpace"

    var body: some View {
        @Bindable var popover = popover
        return modeBody
            .frame(width: PanelMetrics.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.panelBody)
            .modifier(PanelHeightModifier(from: slideStartHeight, to: animatedHeight, progress: slideProgress))
            .overlay(alignment: .topLeading) {
                if let reorderLift {
                    ReorderLiftPreview(lift: reorderLift)
                }
            }
            .coordinateSpace(name: Self.reorderSpace)
            .environment(\.concealsAccountNames, container.hideFromScreenShare.isConcealing)
            .sheet(isPresented: $popover.isAddingAccount, onDismiss: { popover.signingInAgainProviderID = nil }) {
                AddAccountSheet(flow: AddAccountFlow(
                    store: container.accounts,
                    connectHub: { url, key in try await container.hubs.connect(url: url, key: key) },
                    replaceCredential: { credential, id in try await container.signInAgain(credential, for: id) },
                    signingInAgainTo: popover.signingInAgainProviderID.flatMap(container.accounts.account(cardID:))
                ))
            }
            .background(
                PopoverKeyReader { key in
                    switch key {
                    case .escape:
                        return popover.back()
                    case .return:
                        guard popover.screen == .dashboard else { return popover.back() }
                        popover.toggle(.accounts)
                    case .settings:
                        popover.toggle(.settings)
                    case .undo:
                        if layout.canUndo { withAnimation(Motion.spring) { _ = layout.undo() } }
                    }
                    return true
                }
            )
            .onChange(of: popover.popoverShown) { _, shown in
                if shown {
                    if let target = heightTarget(for: popover.screen) { setHeightTarget(target, immediately: true) }
                    isOpening = true
                    openingSlideID = popover.screenSlideID
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        isOpening = false
                    }
                } else {
                    resetTransientState()
                }
            }
            // A screen switch can tear the list down mid-drag, in which case the gesture's
            // `onEnded` never fires — clear the lift here or its overlay survives onto the new
            // screen.
            .onChange(of: popover.screen) { _, screen in
                reorderLift = nil
                if screen == .settings { hasVisitedSettings = true }
                if screen == .accounts { Task { await container.hubs.syncDue(maxAge: 60) } }
            }
            .onChange(of: popover.customizeProviderID) { reorderLift = nil }
            .onChange(of: popover.accountsPage) { slideHeightWithPage() }
            // Each screen switch: pin to the outgoing screen for one render, then slide to the incoming
            // one on the next runloop tick. `slideProgress` drives the page offset and the panel's height,
            // so the screens slide and the panel resizes on one curve.
            .onChange(of: popover.screenSlideID) { _, id in
                guard id != 0 else { return }
                // A slide the user starts on the open panel ends the opening window so it animates. The
                // slide back to the dashboard when the panel closes leaves the next opening alone.
                if popover.popoverShown, id != openingSlideID { isOpening = false }
                if reduceAnimations {
                    animatedSlideID = id
                    settledSlideID = id
                    slideProgress = 1
                    if let target = heightTarget(for: popover.screen) { setHeightTarget(target, immediately: true) }
                    return
                }
                restartSlideProgress()
                animatedSlideID = id
                let destination = popover.screen
                Task { @MainActor in
                    if let target = heightTarget(for: destination) { setHeightTarget(target) }
                    withAnimation(Motion.navigation, completionCriteria: .removed) {
                        slideProgress = 1
                    } completion: {
                        settledSlideID = id
                    }
                }
            }
            // A page measures again as it lays out, and the first report of a page the slide mounts comes
            // before its bars are inset. Each report only moves where the panel is headed.
            .onChange(of: measuredIdeal[popover.screen, popover.dashboardTab]) { _, _ in
                guard let target = heightTarget(for: popover.screen) else { return }
                setHeightTarget(target, immediately: isOpening)
            }
    }

    /// Heads the panel for `target`. Outside a slide or page push it gets there in one step, like a
    /// native window. During one, the start is moved so the panel goes on from the height it is at and
    /// still arrives with the motion. With `immediately`, or before the panel has a height, it is there
    /// at once.
    private func setHeightTarget(_ target: CGFloat, immediately: Bool = false) {
        defer {
            didEstablishHeight = true
            animatedHeight = target
        }
        let presented = PanelHeightModifier.presented
        guard !immediately, didEstablishHeight, presented.height > 0, presented.progress < 1 else {
            slideStartHeight = target
            return
        }
        slideStartHeight = (presented.height - target * presented.progress) / (1 - presented.progress)
    }

    /// Pins the panel to the height it is at and the pager to the outgoing screen for one render. The
    /// caller animates `slideProgress` to 1 on the next runloop tick: setting 0 then 1 in the same
    /// closure collapses to a no-op, since SwiftUI animates from the last committed value.
    private func restartSlideProgress() {
        // SwiftUI adds what is left of a running motion to the new one, so the drawn progress drops by
        // the 1 it was headed for, not to 0. A motion interrupted midway goes on from where it is.
        PanelHeightModifier.presented.progress -= 1
        withAnimation(nil) {
            slideProgress = 0
            setHeightTarget(animatedHeight)
        }
    }

    /// Opening or leaving an account or hub page moves the panel to the new page's height in one
    /// motion along with the page. A page change that comes with a screen slide rides that slide.
    private func slideHeightWithPage() {
        guard !reduceAnimations, !isSliding else { return }
        restartSlideProgress()
        Task { @MainActor in
            withAnimation(Motion.navigation) { slideProgress = 1 }
        }
    }

    private func resetTransientState() {
        container.renaming.commit()
        popover.reset()
        reorderLift = nil
        animatedHeight = 0
        didEstablishHeight = false
        dashboardScrollPosition.scrollTo(edge: .top)
    }

    /// Why an offset and not a SwiftUI `.transition`: the cards' fill is translucent `.quaternary`
    /// glass. Any transition carrying `.opacity` composites a screen into a transparency layer where
    /// that material has no vibrant backdrop to sample and resolves to its opaque near-white base — a
    /// white flash across the grey cards, which no SwiftUI transition avoids.
    /// A pure offset never touches opacity, so the glass keeps sampling the live popover backdrop. The
    /// pages are a `ForEach` keyed by screen, so the incoming page keeps its identity (and scroll
    /// position) when the slide collapses back to one page. Settings lives in a sibling overlay after
    /// its first visit so its expensive native controls survive navigation; an empty pager slot keeps
    /// its slide geometry unchanged. `.animation(nil, value:)` stops the
    /// one-frame structural re-layout at the start of a switch from inheriting the footer buttons'
    /// mode-switch animation — only `slideProgress` animates the offset.
    private var modeBody: some View {
        let pages = slidePages
        let pagerOffset = slideOffset(pages)
        let keepSettings = isSettingsKeptAlive
        return ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(pages, id: \.self) { screen in
                    pagerPage(screen, settingsKeptAlive: keepSettings)
                        .frame(width: PanelMetrics.width)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: PanelMetrics.width, alignment: .leading)
            .offset(x: pagerOffset)

            if keepSettings {
                screenView(.settings, includeChrome: Self.settingsChromeIsVisible(pages: pages))
                    .frame(width: PanelMetrics.width)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .offset(x: Self.settingsOverlayOffset(
                        pages: pages,
                        slideOffset: pagerOffset,
                        pageWidth: PanelMetrics.width
                    ))
                    .allowsHitTesting(popover.screen == .settings)
                    .accessibilityHidden(popover.screen != .settings)
            }
        }
        .frame(width: PanelMetrics.width, alignment: .leading)
        .animation(nil, value: popover.screenSlideID)
    }

    private var isSettingsKeptAlive: Bool {
        hasVisitedSettings || popover.screen == .settings
    }

    @ViewBuilder
    private func pagerPage(_ screen: PopoverScreen, settingsKeptAlive: Bool) -> some View {
        if screen == .settings && settingsKeptAlive {
            Color.clear
                .allowsHitTesting(false)
        } else {
            screenView(screen)
        }
    }

    static func settingsOverlayOffset(
        pages: [PopoverScreen],
        slideOffset: CGFloat,
        pageWidth: CGFloat
    ) -> CGFloat {
        if let index = pages.firstIndex(of: .settings) {
            return CGFloat(index) * pageWidth + slideOffset
        }
        return pageWidth * 2
    }

    static func settingsChromeIsVisible(pages: [PopoverScreen]) -> Bool {
        pages.contains(.settings)
    }

    private var isSliding: Bool {
        Self.screenTransitionIsActive(
            reduceAnimations: reduceAnimations,
            screenSlideID: popover.screenSlideID,
            settledSlideID: settledSlideID
        )
    }

    static func screenTransitionIsActive(
        reduceAnimations: Bool,
        screenSlideID: Int,
        settledSlideID: Int
    ) -> Bool {
        !reduceAnimations
            && screenSlideID != 0
            && screenSlideID != settledSlideID
    }

    private var slidePages: [PopoverScreen] {
        guard isSliding else { return [popover.screen] }
        let from = popover.screenSlideFrom
        let to = popover.screen
        return from.slideRank < to.slideRank ? [from, to] : [to, from]
    }

    private func slideOffset(_ pages: [PopoverScreen]) -> CGFloat {
        guard isSliding, pages.count > 1 else { return 0 }
        let fromOffset = -CGFloat(pages.firstIndex(of: popover.screenSlideFrom) ?? 0) * PanelMetrics.width
        let toOffset = -CGFloat(pages.firstIndex(of: popover.screen) ?? 0) * PanelMetrics.width
        let progress = animatedSlideID == popover.screenSlideID ? slideProgress : 0
        return fromOffset + progress * (toOffset - fromOffset)
    }

    @ViewBuilder
    private func screenView(_ screen: PopoverScreen, includeChrome: Bool = true) -> some View {
        scrollBody(for: screen)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, height in
                if includeChrome, height > 0 { measuredIdeal[screen, popover.dashboardTab] = height }
            }
            .panelBars {
                if includeChrome {
                    PopoverTopBar(screen: screen)
                        .animation(pageAnimation, value: popover.accountsPage)
                }
            } bottom: {
                if includeChrome {
                    PopoverFooter(screen: screen)
                }
            }
    }

    /// How an account or hub page and its header swap in. The page changes without a transaction
    /// animation and only the page and header animate, so the bars' space switches in the same frame as
    /// the page and the panel resizes once with it instead of following the footer as it shrinks or
    /// grows. During a screen slide the page swaps at once, as the rest of the outgoing screen does.
    private var pageAnimation: Animation? {
        isSliding ? nil : Motion.navigation
    }

    private func heightTarget(for screen: PopoverScreen) -> CGFloat? {
        measuredIdeal[screen, popover.dashboardTab].map { MenuBarPopover.clampHeight?($0) ?? $0 }
    }

    @ViewBuilder
    private func scrollBody(for screen: PopoverScreen) -> some View {
        switch screen {
        case .dashboard:
            DashboardContentView(
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift,
                scrollPosition: $dashboardScrollPosition
            )
        case .accounts:
            AccountsView(
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift,
                pageAnimation: pageAnimation
            )
        case .settings:
            SettingsScreen()
        }
    }
}

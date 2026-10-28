import SwiftUI

struct DashboardView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    @Environment(\.reduceAnimations) private var reduceAnimations
    @State private var reorderLift: ReorderLift?
    @State private var animatedHeight: CGFloat = 0
    @State private var didEstablishHeight = false
    @State private var measuredIdeal: [PopoverScreen: CGFloat] = [:]
    @State private var slideProgress: CGFloat = 1
    @State private var animatedSlideID = 0
    /// The `popover.screenSlideID` whose slide has ended. Until the store's id lands here the pager keeps
    /// both screens mounted, so the outgoing one slides away with its chrome. `slideProgress` can't
    /// tell: its model value is 1 from the moment the spring starts, so a pager keyed on it would drop
    /// the outgoing screen on the slide's first frame and leave it fading in place over the incoming one.
    @State private var settledSlideID = 0
    @State private var dashboardScrollPosition = ScrollPosition(edge: .top)
    /// Settings is expensive to mount because each menu picker creates an `NSPopUpButton`. Keep its
    /// view tree alive after the first visit so later screen switches don't rebuild those controls.
    @State private var hasVisitedSettings = false
    private static let reorderSpace = "popoverReorderSpace"
    private static let topBarHeight: CGFloat = 44

    var body: some View {
        @Bindable var popover = popover
        return modeBody
            .frame(width: PanelMetrics.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(PopoverSurface())
            .drivesPanelHeight(animatedHeight)
            .overlay(alignment: .topLeading) {
                if let reorderLift {
                    ReorderLiftPreview(lift: reorderLift)
                }
            }
            .coordinateSpace(name: Self.reorderSpace)
            .sheet(isPresented: $popover.isAddingAccount) {
                AddAccountSheet(flow: AddAccountFlow(store: container.accounts))
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
                    if let target = heightTarget(for: popover.screen) {
                        didEstablishHeight = true
                        animatedHeight = target
                    }
                } else {
                    resetTransientState()
                }
            }
            .onChange(of: popover.dashboardFocusRequestID) { _, _ in consumeWidgetFocus() }
            .onAppear { consumeWidgetFocus() }
            // A screen switch can tear the list down mid-drag, in which case the gesture's
            // `onEnded` never fires — clear the lift here or its overlay survives onto the new
            // screen.
            .onChange(of: popover.screen) { _, screen in
                reorderLift = nil
                if screen == .settings { hasVisitedSettings = true }
            }
            // Each screen switch: pin to the outgoing screen for one render (`slideProgress = 0`),
            // then spring to the incoming one on the next runloop tick. Deferring the animation one
            // tick is what makes it animate — setting 0 then 1 in the same closure collapses to a
            // no-op (SwiftUI animates from the last *committed* value). `slideProgress` drives the
            // page offset so the screens slide between modes on one spring.
            .onChange(of: popover.screenSlideID) { _, id in
                guard id != 0 else { return }
                if reduceAnimations {
                    animatedSlideID = id
                    settledSlideID = id
                    slideProgress = 1
                    if let target = heightTarget(for: popover.screen) {
                        didEstablishHeight = true
                        animatedHeight = target
                    }
                    return
                }
                slideProgress = 0
                animatedSlideID = id
                let destination = popover.screen
                Task { @MainActor in
                    let coTarget: CGFloat? = heightTarget(for: destination)
                        ?? (animatedHeight > 0 ? animatedHeight : nil)
                    if coTarget != nil { didEstablishHeight = true }
                    withAnimation(Motion.spring, completionCriteria: .removed) {
                        slideProgress = 1
                        if let coTarget { animatedHeight = coTarget }
                    } completion: {
                        settledSlideID = id
                        guard let target = heightTarget(for: popover.screen) else { return }
                        if !didEstablishHeight {
                            didEstablishHeight = true
                            animatedHeight = target
                        } else if abs(target - animatedHeight) > 1 {
                            withAnimation(Motion.spring) { animatedHeight = target }
                        }
                    }
                }
            }
            .onChange(of: measuredIdeal[popover.screen]) { _, _ in
                guard let target = heightTarget(for: popover.screen) else { return }
                if !didEstablishHeight {
                    didEstablishHeight = true
                    animatedHeight = target
                } else if !isSliding, abs(target - animatedHeight) > 1 {
                    withAnimation(Motion.spring) { animatedHeight = target }
                }
            }
    }

    private func resetTransientState() {
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        container.renaming.commit()
        popover.reset()
        reorderLift = nil
        animatedHeight = 0
        didEstablishHeight = false
        dashboardScrollPosition.scrollTo(edge: .top)
    }

    private func consumeWidgetFocus() {
        guard popover.screen == .dashboard,
              let id = popover.dashboardFocusProviderID,
              layout.displayGroups.contains(where: { $0.provider.id == id }) else { return }
        let requestID = popover.dashboardFocusRequestID
        dashboardScrollPosition.scrollTo(id: id, anchor: .top)
        popover.acknowledgeDashboardFocus(requestID: requestID)
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
                if includeChrome, height > 0 { measuredIdeal[screen] = height }
            }
            .softScrollEdges()
            .pinnedBar(.top, spacing: 0) {
                if includeChrome {
                    PopoverTopBar(
                        screen: screen,
                        height: Self.topBarHeight,
                        horizontalPadding: PanelMetrics.margin
                    )
                }
            }
            .pinnedBar(.bottom, spacing: 0) {
                if includeChrome {
                    PopoverFooter(screen: screen, horizontalPadding: PanelMetrics.margin)
                }
            }
    }

    private func heightTarget(for screen: PopoverScreen) -> CGFloat? {
        measuredIdeal[screen].map { MenuBarPopover.clampHeight?($0) ?? $0 }
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
                reorderLift: $reorderLift
            )
        case .settings:
            SettingsScreen()
        }
    }
}

private struct PopoverSurface: View {
    var body: some View {
        Theme.traySurface.allowsHitTesting(false)
    }
}

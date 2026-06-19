import SwiftUI
import AppKit

/// The popover content: the provider/metric list (or the Customize / Settings screen) as a scroll
/// view above a single pinned footer — app identity (or the "Customize" mode label) plus the live
/// refresh countdown on the leading edge, and the glass Customize + Settings buttons on the
/// trailing edge.
///
/// The footer is pinned via `pinnedFooter`, so the scrolling content underlaps it and macOS's native
/// scroll edge effect (the blur/fade as content passes under a bar) handles the bottom transition —
/// no custom gradient mask. On macOS 26 that's `safeAreaBar`; on macOS 15 it falls back to
/// `safeAreaInset`, which still pins the footer but without the scroll-edge blur (content scrolls
/// flush to it). The popover height is clamped to a share of the hosting screen so it never overflows
/// when many widgets are added.
struct DashboardView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @State private var listContentHeight: CGFloat = 300
    @State private var customizeContentHeight: CGFloat = 220
    @State private var settingsContentHeight: CGFloat = 480
    @State private var footerHeight: CGFloat = 46
    @State private var usableHeight: CGFloat = ScreenHeightReader.smallestUsableHeight()
    @State private var didInitialRefresh = false
    @State private var hasMeasuredCustomizeContent = false
    @State private var hasMeasuredSettingsContent = false
    @State private var reorderLift: ReorderLift?
    /// Horizontal screen-switch slide: 0 shows the outgoing screen, 1 the incoming one. Drives both the
    /// page offset and the interpolated popover height, so the slide and the resize share one spring.
    @State private var slideProgress: CGFloat = 1
    /// The `layout.screenSlideID` whose slide has begun animating. Until it catches up to the store's
    /// id, a freshly-started transition pins to the outgoing screen so the first frame never flashes
    /// the destination.
    @State private var animatedSlideID = 0
    /// Reset to the top whenever the popover closes, so it never reopens mid-scroll.
    @State private var dashboardScrollPosition = ScrollPosition(edge: .top)
    /// Row rhythm and the Customize height seed track the global density setting live.
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    /// Readability control. The app toggle is OR'd with macOS's own Reduce Transparency setting
    /// (`accessibilityReduceTransparency`) into one `effectiveReduceTransparency` flag, pushed down
    /// the tree so every surface renders in its solid form together.
    @AppStorage(ReduceTransparencySetting.key) private var reduceTransparency = false
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    private static let outerPadding: CGFloat = 14
    /// Breathing room between the bottom of the scrolling content and the pinned footer. Kept small
    /// because the native scroll edge effect — not whitespace — provides the visual separation.
    private static let contentBottomGap: CGFloat = 12
    /// Footer content starts at the same standard padding as the provider containers.
    private static let footerHorizontalPadding: CGFloat = outerPadding
    private static let reorderSpace = "popoverReorderSpace"
    /// One width across both densities — switching density shouldn't move the popover's left edge.
    private static let popoverWidth: CGFloat = 320

    /// Never grow taller than 85% of the *hosting* screen's usable height; scroll beyond that. All
    /// three screens (dashboard, Customize, Settings) share this one cap so they feel consistent —
    /// each fits its content exactly until it would exceed the cap, then scrolls.
    private var maxHeight: CGFloat {
        floor(usableHeight * 0.85)
    }

    /// The pinned footer lives outside the scroll region, so the scroll area's cap is the popover cap
    /// minus that fixed chrome.
    private var chromeHeight: CGFloat {
        footerHeight
    }

    private var maxScrollHeight: CGFloat {
        max(120, maxHeight - chromeHeight)
    }

    /// The scroll area fits its content exactly until it would exceed the cap, then it scrolls.
    private var dashboardScrollHeight: CGFloat {
        min(listContentHeight, maxScrollHeight)
    }

    private var customizeScrollHeight: CGFloat {
        let contentHeight = hasMeasuredCustomizeContent ? customizeContentHeight : estimatedCustomizeContentHeight
        return min(contentHeight, maxScrollHeight)
    }

    /// Settings fits its content exactly, like the dashboard and Customize, up to the global cap.
    /// Before the first measurement an estimate seeds the height so the flip lands close and the
    /// real measurement only fine-tunes it.
    private var settingsScrollHeight: CGFloat {
        let contentHeight = hasMeasuredSettingsContent ? settingsContentHeight : estimatedSettingsContentHeight
        return min(contentHeight, maxScrollHeight)
    }

    private func scrollHeight(for screen: PopoverScreen) -> CGFloat {
        switch screen {
        case .dashboard: dashboardScrollHeight
        case .customize: customizeScrollHeight
        case .settings: settingsScrollHeight
        }
    }

    private var popoverHeight: CGFloat {
        scrollHeight(for: layout.screen) + chromeHeight
    }

    /// The popover height to apply while a screen-switch slide is playing: it interpolates from the
    /// outgoing screen's height to the incoming one's on `slideProgress` — the *same* value that drives
    /// the horizontal offset — so the box resizing and the screens sliding read as one coordinated
    /// motion instead of two animations on separate clocks. At rest it's simply the current screen's
    /// height; before the slide actually starts it sits at the outgoing screen's height to match the
    /// pinned offset, so nothing jumps ahead of the slide.
    private var animatedPopoverHeight: CGFloat {
        guard isSliding else { return popoverHeight }
        let fromHeight = scrollHeight(for: layout.screenSlideFrom) + chromeHeight
        guard animatedSlideID == layout.screenSlideID else { return fromHeight }
        return fromHeight + slideProgress * (popoverHeight - fromHeight)
    }

    /// Cold-start estimate for Customize content. Without this, the first click into Customize starts from an
    /// arbitrary seed height, then jumps when the real `ScrollView` measurement arrives. The constants mirror
    /// `CustomizeView`'s row/block spacing closely enough to choose the same clamped height before first layout.
    private var estimatedCustomizeContentHeight: CGFloat {
        let groups = layout.customizeGroups
        guard !groups.isEmpty else { return 104 }
        let providerHeaderHeight: CGFloat = density == .compact ? 26 : 30
        let providerHeaderToCardSpacing: CGFloat = density.headerToCardSpacing + 2
        let metricRowHeight = density.estimatedMetricRowHeight
        let providerSpacing = density.sectionSpacing
        let verticalPadding: CGFloat = 24
        let blocks = groups.reduce(CGFloat.zero) { total, group in
            total + providerHeaderHeight + providerHeaderToCardSpacing + CGFloat(group.metrics.count) * metricRowHeight
        }
        return verticalPadding + blocks + CGFloat(max(0, groups.count - 1)) * providerSpacing
    }

    /// Cold-start estimate for Settings content, same role as the Customize estimate above. The
    /// constants mirror `SettingsScreen`: five sections (a caption header over a card) holding
    /// twelve fixed control rows (Startup 2, Appearance 5, Usage Display 2, Advanced 3) plus one
    /// row per registered provider.
    private var estimatedSettingsContentHeight: CGFloat {
        let sectionCount: CGFloat = 5
        let sectionHeaderHeight: CGFloat = 16
        let fixedRowCount: CGFloat = 12
        let rowCount = fixedRowCount + CGFloat(container.registry.providers.count)
        let verticalPadding: CGFloat = 24
        return verticalPadding
            + sectionCount * (sectionHeaderHeight + density.headerToCardSpacing)
            + rowCount * density.estimatedMetricRowHeight
            + (sectionCount - 1) * density.sectionSpacing
    }

    /// The app's Reduce Transparency toggle OR macOS's own accessibility setting: either one drops
    /// the popover to its solid, non-glass form. Resolved once here and injected so the surface,
    /// controls, and meter tints all read the same answer.
    private var effectiveReduceTransparency: Bool {
        reduceTransparency || systemReduceTransparency
    }

    var body: some View {
        modeBody
            .frame(width: Self.popoverWidth)
            .pinnedFooter(spacing: 0) { footerBar }
            .frame(height: animatedPopoverHeight, alignment: .top)
            // Paint the surface behind the content (and footer) and tell every descendant whether
            // glass is on, so the fallbacks and the meter tints render in step. Both go on the
            // outermost level of the chain so the footer, header buttons, and scroll content inherit.
            .background(
                PopoverSurface(reduce: effectiveReduceTransparency)
            )
            .environment(\.reduceTransparencyEffective, effectiveReduceTransparency)
            .overlay(alignment: .topLeading) {
                if let reorderLift {
                    ReorderLiftPreview(lift: reorderLift)
                }
            }
            .coordinateSpace(name: Self.reorderSpace)
            .background(ScreenHeightReader(usableHeight: $usableHeight))
            .background(
                // Esc backs out of Customize / Settings first; only from the dashboard does it close
                // the popover. Return opens Customize from the dashboard (the affordance the standalone
                // Customize button carried before it folded into the More menu) and returns to the
                // dashboard from Customize or Settings — matching Esc and the prominent "Done" control,
                // never jumping Settings → Customize. Always consumed, so a bare Return can't fall
                // through and dismiss the popover.
                PopoverKeyReader(
                    onEscape: {
                        guard layout.screen != .dashboard else { return false }
                        withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
                        return true
                    },
                    onReturn: {
                        let target: PopoverScreen = layout.screen == .dashboard ? .customize : .dashboard
                        withAnimation(Motion.modeSwitch) { layout.screen = target }
                        return true
                    }
                )
            )
            .background(
                PopoverVisibilityReader { visible in
                    if !visible { resetTransientState() }
                }
            )
            // A screen switch can tear the list down mid-drag, in which case the gesture's
            // `onEnded` never fires — clear the lift here or its overlay survives onto the new
            // screen.
            .onChange(of: layout.screen) {
                reorderLift = nil
                layout.cancelDrag()
            }
            // Each screen switch: pin to the outgoing screen for one render (`slideProgress = 0`),
            // then spring to the incoming one on the next runloop tick. Deferring the animation one
            // tick is what makes it animate — setting 0 then 1 in the same closure collapses to a
            // no-op (SwiftUI animates from the last *committed* value). `slideProgress` drives the
            // page offset and the interpolated height together, so the slide and the resize are one motion.
            .onChange(of: layout.screenSlideID) { _, id in
                guard id != 0 else { return }
                slideProgress = 0
                animatedSlideID = id
                Task { @MainActor in
                    withAnimation(Motion.spring) { slideProgress = 1 }
                }
            }
            .onChange(of: layout.customizeGroups.map { group in
                "\(group.provider.id):\(group.metrics.map(\.id).joined(separator: ","))"
            }) {
                hasMeasuredCustomizeContent = false
            }
            .task {
                guard !didInitialRefresh else { return }
                didInitialRefresh = true
                await dataStore.refreshAll()
            }
    }

    private func resetTransientState() {
        if layout.screen != .dashboard { layout.screen = .dashboard }
        reorderLift = nil
        layout.cancelDrag()
        dashboardScrollPosition.scrollTo(edge: .top)
    }

    /// The popover's screens as a horizontal pager. At rest only the current screen is mounted (one
    /// page at offset 0), so drag-reorder's coordinate math and the footer's scroll-edge underlap are
    /// exactly what they'd be with the screen rendered alone. During a switch the outgoing and incoming
    /// screens are both mounted, ordered left-to-right by `slideRank`, and slid by a pure offset.
    ///
    /// Why an offset and not a SwiftUI `.transition`: the cards' fill is translucent `.quaternary`
    /// glass. Any transition carrying `.opacity` composites a screen into a transparency layer where
    /// that material has no vibrant backdrop to sample and resolves to its opaque near-white base — a
    /// white flash across the grey cards (the regression this removes; it has no clean SwiftUI fix).
    /// A pure offset never touches opacity, so the glass keeps sampling the live popover backdrop. The
    /// pages are a `ForEach` keyed by screen, so the incoming page keeps its identity (and scroll
    /// position) when the slide collapses back to one page. `.animation(nil, value:)` stops the
    /// one-frame structural re-layout at the start of a switch from inheriting the footer buttons'
    /// mode-switch animation — only `slideProgress` animates the offset (and, in step, the height).
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

    /// Builds one screen. Kept identity-stable across the slide via the `ForEach` key in `modeBody`.
    @ViewBuilder
    private func screenView(_ screen: PopoverScreen) -> some View {
        switch screen {
        case .dashboard:
            scrollingDashboard
        case .customize:
            CustomizeView(
                contentHeight: $customizeContentHeight,
                hasMeasuredContent: $hasMeasuredCustomizeContent,
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift
            )
        case .settings:
            SettingsScreen(
                contentHeight: $settingsContentHeight,
                hasMeasuredContent: $hasMeasuredSettingsContent
            )
        }
    }

    /// The widget list as a scroll view that fills the region the footer leaves. The content scrolls
    /// under the footer; the native scroll edge effect handles the visual transition. Unlike the
    /// Customize/Settings screens it tracks the dashboard's own scroll position and adds the top
    /// soft edge effect (`softTopScrollEdge`, a no-op on macOS 15 where content scrolls flush to the
    /// top), so those modifiers wrap the shared measuring container here.
    private var scrollingDashboard: some View {
        MeasuredScrollScreen(onMeasure: { newValue in
            if newValue > 0 { listContentHeight = newValue }
        }) {
            widgetContent
                .padding(.horizontal, Self.outerPadding)
                .padding(.top, density.contentTopPadding)
                .padding(.bottom, Self.contentBottomGap)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($dashboardScrollPosition)
        .softTopScrollEdge()
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

    // MARK: - Pinned footer

    /// The single bottom footer: app identity (or the "Customize" mode label while editing) plus the
    /// live refresh countdown on the leading edge, and the glass Customize + Settings buttons on the
    /// trailing edge. Pinned via `pinnedFooter` so the content scrolls under it with the native scroll
    /// edge effect (`safeAreaBar` on macOS 26; `safeAreaInset` on macOS 15, where the footer still
    /// pins but the scroll-edge blur is absent).
    private var footerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            footerIdentity
            Spacer(minLength: 8)
            HeaderView()
        }
        .padding(.horizontal, Self.footerHorizontalPadding)
        // Balanced vertical padding so the footer content sits evenly between the bar's edges. The
        // scroll edge blur spans the bar's full height regardless, so the transition stays smooth.
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newValue in
            if newValue > 0 { footerHeight = newValue }
        }
    }

    /// Leading side of the footer. Normal mode shows the app name with the live "Next update in …"
    /// line beneath it; Customize mode shows the pin count ("4 pinned") in the same slot.
    /// Settings keeps the normal identity — the version line doubles as the About info there.
    /// A denied pin attempt swaps either line for the reason (in orange), played with the macOS
    /// deny shake — the wrong-password idiom — on every blocked click.
    @ViewBuilder
    private var footerIdentity: some View {
        if layout.isEditing {
            Text(layout.pinLimitNotice ?? "\(layout.pinnedCount) pinned")
                .font(.caption.weight(.semibold))
                .foregroundStyle(layout.pinLimitNotice == nil ? AnyShapeStyle(.secondary) : Theme.notice)
                .denyShake(trigger: layout.pinNoticeShakeTrigger)
                .animation(Motion.spring, value: layout.pinLimitNotice)
        } else {
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
        .help("Refresh now (⌘R)")
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

/// The popover's backdrop: clear by default (so the system Liquid Glass shows through), an opaque
/// window-colored fill when Reduce Transparency is on. With the default (glass on) it's
/// `Color.clear` — the stock look, untouched. Never hit-tests so it can't steal clicks from the
/// content above it.
private struct PopoverSurface: View {
    let reduce: Bool

    var body: some View {
        Group {
            if reduce {
                // Solid mode: the standard window background, so the popover reads like a normal
                // opaque panel instead of sampling the desktop behind it.
                Color(nsColor: .windowBackgroundColor)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
    }
}

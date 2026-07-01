import AppKit
import KeyboardShortcuts
import SwiftUI

/// The dashboard's host window: a borderless, **non-activating** panel that can still become key.
///
/// This is the fix for `NSPopover`'s fundamental limitation in a menu-bar accessory app. A popover's
/// window is only key while the whole app is active, and activating an `LSUIElement` app is
/// asynchronous — on macOS 26+ it lands several runloop ticks later or is denied — so the popover is
/// on-screen but not key, the keystroke goes to the focused status-item button instead (Enter
/// re-toggles it shut; Esc is lost), and you need a second click/keypress. A `.nonactivatingPanel`
/// whose `canBecomeKey` is `true` becomes key the instant it's ordered front, *without* activating the
/// app, so keyboard input (Esc/Return navigation, the Settings shortcut recorder) works on the first
/// try. (The pattern keyboard-first menu-bar apps use; cross-checked via GitHits.)
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the menu-bar status item and the panel that shows the dashboard.
///
/// Deliberately not SwiftUI's `MenuBarExtra`: its `.window` panel never became a proper key window for
/// text input (the Settings shortcut recorder silently ignored key presses) and there is no public API
/// to present it programmatically. A plain `NSStatusItem` + a key-capable `NSPanel` gives a real key
/// window and a real show/hide pair the global shortcut can call directly.
@MainActor
final class StatusItemController: NSObject {
    private let container: AppContainer
    private let updater: UpdaterController
    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private let hostingController: NSHostingController<AnyView>
    /// The screen the status-item button is on, captured on show — used to clamp the saved panel size
    /// to whatever display the panel is currently opening on.
    private var anchorScreen: NSScreen?
    /// Closes the panel on clicks outside it (the panel is non-activating and dismissal is ours to
    /// implement, the same model the old `.applicationDefined` popover used).
    private var outsideClickMonitors: [Any] = []
    /// Token for the appearance-change observer; held to follow the documented removal pattern.
    private var appearanceObserver: NSObjectProtocol?
    /// Panel top-left in screen coords, captured on show. The panel grows downward from here, so the
    /// top edge stays pinned just under the status-item button as the user resizes it.
    private var anchorTopLeft: NSPoint?

    /// One width across both densities (matches `DashboardView.popoverWidth`). The panel is a single
    /// column of metrics, so width is fixed; only height is user-resizable.
    private static let panelWidth: CGFloat = 320
    /// Gap between the menu bar and the panel's top edge.
    private static let topGap: CGFloat = 4
    /// Corner radius of the panel surface; tuned to read like a system menu-bar popover.
    private static let cornerRadius: CGFloat = 13
    /// Smallest the panel can be — room for the footer plus a single provider card. Kept low so the
    /// auto-fit morph can shrink the panel to match its content instead of showing blank space when
    /// only one or two providers are enabled (#800).
    private static let minPanelHeight: CGFloat = 200
    /// Opening height before the user has ever resized the panel.
    private static let defaultPanelHeight: CGFloat = 800
    /// True while a SwiftUI-driven height morph is in flight. Outside-click dismissal is suspended for
    /// its duration so the panel growing/shrinking under a stationary cursor can't be misread as an
    /// outside click. Cleared by `scheduleMorphSettle` shortly after the per-frame height stream stops.
    private var isMorphing = false
    /// Fires once the per-frame height stream goes quiet: clears `isMorphing` and persists the settled
    /// per-screen height (the next open's flash-free starting guess).
    private var morphSettleTask: Task<Void, Never>?

    init(container: AppContainer, updater: UpdaterController) {
        self.container = container
        self.updater = updater
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let hosting = NSHostingController(
            rootView: AnyView(
                DashboardView()
                    .environment(container)
                    .environment(container.layout)
                    .environment(container.dataStore)
                    .environment(updater)
            )
        )
        // The panel is a fixed, user-resizable size — NOT content-sized. The host view fills the
        // window (its autoresizing mask) and the content scrolls, so switching screens never resizes
        // the window. That's what removes the resize stutter: the only resize is the user's own drag.
        self.hostingController = hosting

        self.panel = MenuBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.defaultPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        configurePanel()
        configureStatusItem()
        updateButtonImage()

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSetting.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.appearance = AppearanceSetting.current.nsAppearance
            }
        }
        // Registered once here; the controller lives for the app's whole life.
        KeyboardShortcuts.onKeyUp(for: .togglePopover) { [weak self] in
            AppLog.info(.statusItem, "Global shortcut fired; toggling popover")
            self?.togglePopover()
        }

        // Esc on the dashboard (and the footer's close affordances) dismiss through the same code
        // path as a status-item click.
        MenuBarPopover.dismissHandler = { [weak self] in
            self?.hidePanel()
        }

        // The panel auto-fits its content: SwiftUI owns one animated height (the single animation
        // clock) and the panel just follows it. `applyHeight` is the per-frame follower; `clampHeight`
        // shares the panel's [min, screen-max] clamp so SwiftUI's target matches where the frame lands.
        MenuBarPopover.applyHeight = { [weak self] height in self?.applyMorphHeight(height) }
        MenuBarPopover.clampHeight = { [weak self] raw in
            guard let self else { return raw }
            return min(max(raw, Self.minPanelHeight), self.maxPanelHeight())
        }

        AppLog.info(.statusItem, "Status item ready (button: \(self.statusItem.button != nil), shortcut: \(KeyboardShortcuts.getShortcut(for: .togglePopover)?.description ?? "none"))")
    }

    // MARK: - Panel configuration

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Pin the theme override (nil for System) so the menu bar's appearance doesn't win; tracked
        // live by `appearanceObserver`.
        panel.appearance = AppearanceSetting.current.nsAppearance

        let container = NSView()

        // Opaque backdrop: the popover is a solid panel — the data region never shows the desktop
        // through it. Liquid Glass is reserved for the footer chrome (its frosted bar + controls),
        // rendered in-window over this opaque backing, never behind the data. The box fills the whole
        // window, so a screen-switch resize can't briefly reveal a transparent strip beneath the
        // content-sized SwiftUI surface, and any region SwiftUI leaves unpainted shows this opaque
        // tray, not a hole to the desktop. `Theme.trayNSColor` tracks light/dark (and the forced
        // appearance override) and matches the SwiftUI tray (`DashboardView.PopoverSurface`); rounded
        // via `cornerRadius` so it follows the panel's shape. `panel.appearance` (tracked by
        // `appearanceObserver`) pins the light/dark mode.
        let backdrop = NSBox()
        backdrop.boxType = .custom
        backdrop.titlePosition = .noTitle
        backdrop.borderWidth = 0
        backdrop.cornerRadius = Self.cornerRadius
        backdrop.contentViewMargins = .zero
        backdrop.fillColor = Theme.trayNSColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let host = hostingController.view
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        // Redraw the SwiftUI content on every step of a live resize instead of stretching the layer's
        // cached contents (the default `.onSetNeedsDisplay`), which is what made the cards jitter while
        // dragging the bottom edge.
        host.layerContentsRedrawPolicy = .duringViewResize
        host.layer?.cornerRadius = Self.cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        container.addSubview(backdrop)
        container.addSubview(host, positioned: .above, relativeTo: backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // A plain container VC owns the backdrop; the hosting controller is its child so SwiftUI gets
        // a proper view-controller hierarchy. The panel itself is sized by `applyPanelSize`.
        let rootVC = NSViewController()
        rootVC.view = container
        rootVC.addChild(hostingController)
        panel.contentViewController = rootVC
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusButtonClicked)
        // Left-click toggles the popover; right-click (or control-click) drops the context menu.
        // Both arrive through `statusButtonClicked`, which branches on the triggering event.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Status item image

    /// Coalesces re-render requests: a burst of snapshot writes (a multi-provider refresh pass) must
    /// produce ~one re-render, not O(writes) MainActor Task hops + ImageRenderer passes. `nil` when idle.
    private var pendingRenderTask: Task<Void, Never>?

    /// Re-renders the menu-bar strip whenever anything it reads changes (pins, live data, meter
    /// style, menu-bar style). `withObservationTracking`'s `onChange` is one-shot, so each render
    /// re-arms it. The re-arm is debounced (see `scheduleButtonImageUpdate`).
    private func updateButtonImage() {
        let image = withObservationTracking {
            renderButtonImage()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleButtonImageUpdate()
            }
        }
        statusItem.button?.image = image
    }

    /// Debounce the re-render so a refresh-storm burst of snapshot writes collapses into a single
    /// render once the burst settles, instead of one render per write — the feedback loop that can
    /// starve the MainActor and drop the status item (the "menu bar disappears" failure mode).
    private func scheduleButtonImageUpdate() {
        pendingRenderTask?.cancel()
        pendingRenderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.updateButtonImage()
        }
    }

    /// The pinned-metrics strip in the chosen style, or the app icon when nothing is pinned.
    private func renderButtonImage() -> NSImage {
        let content = MenuBarContentBuilder.build(
            groups: container.layout.pinnedGroups,
            data: { container.dataStore.data(for: $0) }
        )
        return MenuBarStripRenderer.image(for: content, style: container.layout.menuBarStyle)
            ?? MenuBarIcon.image
            ?? MenuBarStripRenderer.fallbackIcon
    }

    // MARK: - Show / hide

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isContextClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    /// Right-click / control-click on the status item: a native menu mirroring the popover footer's
    /// "More" items for Settings and Quit (same titles, symbols, and ⌘ shortcuts). Assigning
    /// `statusItem.menu` for the span of one `performClick` shows the menu anchored under the item and
    /// highlights the button, then clearing it restores the left-click toggle behavior.
    private func showContextMenu() {
        // The context menu is a distinct gesture from the left-click popover: close an open panel
        // first so the menu opens over a clean state (no leftover button highlight, no live
        // outside-click monitors racing the menu's own modal tracking).
        if panel.isVisible { hidePanel() }

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Settings", systemSymbol: "gearshape", keyEquivalent: ",") { [weak self] in
            self?.openSettings()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit OpenUsage", systemSymbol: "power", keyEquivalent: "q") {
            NSApplication.shared.terminate(nil)
        })

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Opens the dashboard popover on the Settings screen — Settings is an in-popover screen, not a
    /// separate window. The screen is set before showing the panel so it opens already sized to Settings.
    private func openSettings() {
        container.layout.screen = .settings
        if !panel.isVisible {
            showPanel()
        }
    }

    func togglePopover() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            AppLog.error(.statusItem, "Cannot show panel: status item has no button")
            return
        }
        // Drop any morph heights still queued from a previous session so a quick reopen during an old
        // spring can't apply a stale height to this fresh open.
        PanelHeightBridge.invalidate()
        // Lay the content out first so the panel opens at the right size (no first-frame flash).
        hostingController.view.layoutSubtreeIfNeeded()

        let buttonRectOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        anchorScreen = NSScreen.screens.first { $0.frame.intersects(buttonRectOnScreen) } ?? NSScreen.main
        anchorTopLeft = clampedTopLeft(below: buttonRectOnScreen, width: Self.panelWidth)
        applyPanelSize()

        // `canBecomeKey` + `.nonactivatingPanel` makes this key without activating the app — no
        // activation race, so the dashboard receives keys on the first try.
        panel.makeKeyAndOrderFront(nil)
        // Becoming key, AppKit auto-focuses the first control in the key-view loop (the first row's
        // Used/Left toggle) when system Keyboard Navigation is on — so the popover would open with a
        // stray focus ring nobody asked for. Drop it; keyboard nav still works (it rides a local key
        // monitor, not first responder), and Tab from here focuses the first control as expected.
        clearStrayFocus()
        button.highlight(true)
        startOutsideClickMonitors()
    }

    private func hidePanel() {
        // The popover's SwiftUI tree survives `orderOut`, so a tooltip the cursor was resting on gets
        // no hover-exit and would orphan on screen — clear it here, the one chokepoint every close hits.
        // The Usage Trend hover popover is on the same survives-orderOut footing, so dismiss it too.
        HoverTooltips.dismissAll()
        TrendHoverState.dismissAll()
        // Same survival problem for keyboard focus: a clicked plain-styled control (a row's Used/Left
        // or reset toggle) stays first responder, so its focus ring would reopen with the popover as a
        // stray blue outline. Drop it on close so every reopen starts unfocused.
        clearStrayFocus()
        // Persist the closing screen's height NOW, while `container.layout.screen` is still the screen
        // being shown (the visibility reset that flips it back to dashboard runs later, off the occlusion
        // notification). `scheduleMorphSettle` only persists after 120ms of quiet and bails once the panel
        // is hidden, so without this a close right after a resize/screen-switch would never save the new
        // height and the next open of that screen would use a stale flash-free guess.
        if panel.isVisible {
            PanelHeightStore.save(panel.frame.height, for: container.layout.screen)
        }
        panel.orderOut(nil)
        stopOutsideClickMonitors()
        statusItem.button?.highlight(false)
        anchorTopLeft = nil
        anchorScreen = nil
        // Settle any in-flight morph so a reopen doesn't inherit a stale flag, and invalidate heights
        // already queued through PanelHeightBridge so a spring morph caught mid-flight by the close
        // can't resize the panel after orderOut (or after a quick reopen).
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()
    }

    /// Drops keyboard focus inside the panel so a clicked plain-styled control (a metric row's
    /// Used/Left + reset toggles) doesn't keep the system focus ring lingering as a stray outline:
    /// AppKit leaves the control first responder until focus moves, which a click on empty space or a
    /// close otherwise never does. Skips a live text field / shortcut recorder, whose focus is the
    /// user's intent — mirrors the `NSText` guard `PopoverKeyReader` uses for the same reason.
    private func clearStrayFocus() {
        guard !ShortcutRecorderField.isRecordingActive,
              !(panel.firstResponder is NSText) else { return }
        panel.makeFirstResponder(nil)
    }

    /// Sizes the panel on show to a **flash-free opening guess** — the last settled height for the
    /// screen being opened (or a default) — clamped to fit the current screen, top-left pinned under
    /// the status item. Width is fixed (single-column list).
    ///
    /// The panel auto-fits its content via the SwiftUI morph (`applyMorphHeight`), but that measured
    /// height only lands a runloop turn after the content lays out — too late for the first frame. So
    /// we open at the persisted per-screen guess (kept current by `scheduleMorphSettle`), and SwiftUI
    /// snaps to the exact measured height on appear; when the guess is close the snap is invisible.
    /// Per-screen because `openSettings` opens straight onto Settings, which is a different height than
    /// the dashboard. The clamp keeps a height saved on a big display from running off a short one.
    private func applyPanelSize() {
        guard let anchorTopLeft else { return }
        let saved = PanelHeightStore.load(for: container.layout.screen) ?? Self.defaultPanelHeight
        let height = min(max(saved, Self.minPanelHeight), maxPanelHeight())
        let origin = NSPoint(x: anchorTopLeft.x, y: anchorTopLeft.y - height)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: height)), display: false)
        panel.invalidateShadow()
    }

    // MARK: - Content-driven morph

    /// Per-frame follower for the SwiftUI-driven height morph (the single animation clock). Called once
    /// per animation frame with the interpolated height — already hopped onto the main queue and out of
    /// SwiftUI's layout pass by `PanelHeightBridge`, so this runs synchronously and safely (a synchronous
    /// `setFrame` from inside that pass would re-enter AppKit layout and trip `_NSDetectedLayoutRecursion`).
    /// Single clock: only `setFrame(display:false)`, never `animate:true` / `panel.animator()`, so AppKit
    /// adds no second animation to fight SwiftUI's spring.
    private func applyMorphHeight(_ rawHeight: CGFloat) {
        guard rawHeight > 1 else { return }   // 0 = "not established yet"; ignore the sentinel.
        // Drop heights that arrive after a close. `PanelHeightBridge` hops each frame through
        // `DispatchQueue.main.async`, so a spring morph in flight when the panel closes leaves queued
        // callbacks behind; `orderOut` flips `isVisible` synchronously, so they're rejected here while
        // closed (before any reopen) instead of resizing a hidden — or freshly reopened — panel.
        guard panel.isVisible else { return }
        guard let anchorTopLeft else {
            AppLog.error(.statusItem, "Morph height while visible but no anchor; frame not applied")
            return
        }
        let height = min(max(rawHeight, Self.minPanelHeight), maxPanelHeight())
        // The live frame is the ground truth: apply only when it would actually move (>1pt). This both
        // dedupes redundant per-render pushes and guarantees the frame never stops short of the driven
        // height — there's no separate "last requested" tracking that a skipped apply could desync.
        guard abs(panel.frame.height - height) > 1 else { return }
        let origin = NSPoint(x: anchorTopLeft.x, y: anchorTopLeft.y - height)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: height)), display: false)
        panel.invalidateShadow()
        isMorphing = true
        scheduleMorphSettle()
    }

    /// Clears `isMorphing` and persists the settled height once the per-frame stream goes quiet (a
    /// spring keeps changing the height every frame until it settles, so this only fires at rest).
    private func scheduleMorphSettle() {
        morphSettleTask?.cancel()
        morphSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, self.panel.isVisible else { return }
            self.isMorphing = false
            PanelHeightStore.save(self.panel.frame.height, for: self.container.layout.screen)
        }
    }

    /// The tallest the panel may be on the current screen: the room below its pinned top edge, capped at
    /// 85% of the screen's usable height so it never dominates a large display.
    private func maxPanelHeight() -> CGFloat {
        guard let anchorTopLeft, let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame else {
            return Self.defaultPanelHeight
        }
        let roomBelowAnchor = anchorTopLeft.y - visible.minY - 8
        let aestheticCap = floor(visible.height * 0.85)
        // The ceiling is the room below the pinned top edge (capped at 85% for aesthetics). It is NOT
        // floored at `minPanelHeight`: on a screen too short for the minimum, fitting on-screen wins —
        // the panel becomes smaller than the min rather than running off the bottom edge. `max(1, …)`
        // only guards a degenerate non-positive frame.
        return max(1, min(roomBelowAnchor, aestheticCap))
    }

    /// Places the panel's top-left just below the button, clamped to the button's screen.
    private func clampedTopLeft(below buttonRect: NSRect, width: CGFloat) -> NSPoint {
        var x = buttonRect.minX
        let topY = buttonRect.minY - Self.topGap
        let screen = NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        }
        return NSPoint(x: x, y: topY)
    }

    // MARK: - Outside-click dismissal

    private func startOutsideClickMonitors() {
        stopOutsideClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // NSEvent is not Sendable: pull the window identity out before hopping to the actor.
            let windowID = event.window.map(ObjectIdentifier.init)
            let windowTypeName = event.window.map { String(describing: type(of: $0)) }
            MainActor.assumeIsolated {
                guard let self else { return }
                // `NSEvent.mouseLocation` is the dependable screen-coordinate read (`locationInWindow`
                // is unreliable for windowless / global events), so the status-button match is correct.
                let screenPoint = NSEvent.mouseLocation
                guard !self.shouldKeepPanelOpen(windowID: windowID, windowTypeName: windowTypeName, screenPoint: screenPoint)
                else {
                    // Click landed inside the panel: drop any stray focus ring a previously-clicked
                    // toggle left behind, the way clicking empty space in a normal window does. The
                    // monitor fires before the event reaches the view, so a click that lands on
                    // another control just moves focus there next; empty space leaves it cleared.
                    if self.panel.frame.contains(screenPoint) { self.clearStrayFocus() }
                    return
                }
                self.hidePanel()
            }
            return event
        }) {
            outsideClickMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            // Capture the click location NOW: `mouseLocation` read later (inside the Task) could be
            // stale if the pointer moved before the hop, mis-deciding the status-button / in-panel
            // checks. `NSPoint` is Sendable, so the captured value crosses into the Task safely.
            let screenPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self else { return }
                // While the panel is morphing its height, its frame is moving under a possibly
                // stationary cursor — don't let a click land "outside" a frame that's mid-resize.
                guard !self.isMorphing else { return }
                // Clicking the status item must NOT dismiss here — its own action toggles the panel.
                // Dismissing on this click's mouse-down would close the panel, then the button action
                // would reopen it on mouse-up (the close-then-reopen flicker).
                guard !self.isOnStatusButton(screenPoint: screenPoint),
                      !self.panel.frame.contains(screenPoint) else { return }
                self.hidePanel()
            }
        }) {
            outsideClickMonitors.append(global)
        }
    }

    private func stopOutsideClickMonitors() {
        for monitor in outsideClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitors = []
    }

    /// In-app clicks that must not dismiss: anything inside the panel itself, the status-item button
    /// (its own handler toggles — closing here too would cancel it out and reopen), and menu windows
    /// (the Settings pickers' popup menus and the footer's More menu render in separate `NSMenu`-backed
    /// windows). Status-item clicks can arrive with no window (the menu bar is composited by the Window
    /// Server), so the button is also matched by screen position.
    private func shouldKeepPanelOpen(windowID: ObjectIdentifier?, windowTypeName: String?, screenPoint: NSPoint) -> Bool {
        // The frame is moving mid-morph; a hit-test against it would be racy, so keep the panel open.
        if isMorphing { return true }
        if isOnStatusButton(screenPoint: screenPoint) { return true }
        if panel.frame.contains(screenPoint) { return true }
        guard let windowID, let windowTypeName else { return false }
        if windowID == ObjectIdentifier(panel) { return true }
        if let buttonWindow = statusItem.button?.window, windowID == ObjectIdentifier(buttonWindow) {
            return true
        }
        return windowTypeName.localizedCaseInsensitiveContains("menu")
    }

    private func isOnStatusButton(screenPoint: NSPoint) -> Bool {
        guard let button = statusItem.button, let buttonWindow = button.window else { return false }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return buttonFrame.contains(screenPoint)
    }
}

/// Persists the last settled panel height **per screen**, so the next open starts at a flash-free
/// guess close to what the content will measure (the panel auto-fits, but the measurement lands a tick
/// after the first frame — see `applyPanelSize`). Width is fixed (single-column list), so only height
/// is stored; it's clamped to the current screen on each open. Per-screen because the dashboard,
/// Customize, and Settings are genuinely different heights and `openSettings` opens straight onto one.
private enum PanelHeightStore {
    private static func key(for screen: PopoverScreen) -> String {
        switch screen {
        case .dashboard: "openusage.panel.height.dashboard"
        case .customize: "openusage.panel.height.customize"
        case .settings: "openusage.panel.height.settings"
        }
    }

    static func load(for screen: PopoverScreen) -> CGFloat? {
        let value = UserDefaults.standard.double(forKey: key(for: screen))
        return value > 0 ? CGFloat(value) : nil
    }

    static func save(_ height: CGFloat, for screen: PopoverScreen) {
        UserDefaults.standard.set(Double(height), forKey: key(for: screen))
    }
}

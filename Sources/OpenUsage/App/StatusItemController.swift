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
    /// Observers that re-evaluate Reduce Transparency: the in-app toggle and macOS's own setting.
    private var reduceTransparencyObserver: NSObjectProtocol?
    private var systemReduceObserver: NSObjectProtocol?
    /// The two interchangeable backdrops behind the dashboard: Liquid Glass, or a solid surface when
    /// Reduce Transparency is on. Exactly one is visible (see `applyReduceTransparency`).
    private var glassBackdrop: NSVisualEffectView?
    private var solidBackdrop: NSBox?
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
    /// Smallest the panel can be dragged — room for the footer plus a couple of rows.
    private static let minPanelHeight: CGFloat = 240
    /// Opening height before the user has ever resized the panel.
    private static let defaultPanelHeight: CGFloat = 800
    /// Panel height at the moment a grip drag began; the live height is this plus the drag distance.
    private var gripStartHeight: CGFloat = 0

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
        reduceTransparencyObserver = NotificationCenter.default.addObserver(
            forName: ReduceTransparencySetting.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyReduceTransparency() }
        }
        systemReduceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyReduceTransparency() }
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

        // The in-page resize grip drives the panel height through these (the panel stays the single
        // owner of `setFrame`, resizing synchronously so the content never lags the frame).
        MenuBarPopover.beginResize = { [weak self] in self?.beginGripResize() }
        MenuBarPopover.resizeBy = { [weak self] distance in self?.updateGripResize(by: distance) }
        MenuBarPopover.endResize = { [weak self] in self?.endGripResize() }

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

        // Glass backdrop: the popover material sampling the desktop behind the window — the same
        // Liquid Glass `NSPopover` rendered for free. Rounded via a resizable mask (a plain layer
        // corner-radius leaves the window-server-composited blur square at the edges).
        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = Self.roundedMaskImage(radius: Self.cornerRadius)
        glass.autoresizingMask = [.width, .height]
        glass.frame = container.bounds

        // Solid backdrop for Reduce Transparency: shown instead of the glass. It fills the whole
        // window, so a screen-switch resize can't briefly reveal glass beneath the content-sized
        // SwiftUI surface (the bug this fixes). `NSBox.fillColor` tracks light/dark automatically.
        let solid = NSBox()
        solid.boxType = .custom
        solid.titlePosition = .noTitle
        solid.borderWidth = 0
        solid.cornerRadius = Self.cornerRadius
        solid.contentViewMargins = .zero
        solid.fillColor = .windowBackgroundColor
        solid.isHidden = true
        solid.autoresizingMask = [.width, .height]
        solid.frame = container.bounds

        let host = hostingController.view
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        // Redraw the SwiftUI content on every step of a live resize instead of stretching the layer's
        // cached contents (the default `.onSetNeedsDisplay`), which is what made the cards jitter while
        // dragging the bottom edge.
        host.layerContentsRedrawPolicy = .duringViewResize
        host.layer?.cornerRadius = Self.cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        container.addSubview(glass)
        container.addSubview(solid, positioned: .above, relativeTo: glass)
        container.addSubview(host, positioned: .above, relativeTo: solid)
        glassBackdrop = glass
        solidBackdrop = solid

        // A plain container VC owns the backdrop; the hosting controller is its child so SwiftUI gets
        // a proper view-controller hierarchy. The panel itself is sized by `applyPanelSize`.
        let rootVC = NSViewController()
        rootVC.view = container
        rootVC.addChild(hostingController)
        panel.contentViewController = rootVC

        applyReduceTransparency()
    }

    /// Reduce Transparency — the in-app toggle OR macOS's own accessibility setting — swaps the glass
    /// backdrop for the solid one. The solid view fills the whole window, so it covers any strip the
    /// content-sized SwiftUI surface hasn't caught up to during a screen-switch resize (which would
    /// otherwise flash the glass). Both backdrops round identically, so the swap is invisible at rest.
    private func applyReduceTransparency() {
        let reduce = ReduceTransparencySetting.current
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        glassBackdrop?.isHidden = reduce
        solidBackdrop?.isHidden = !reduce
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusButtonClicked)
        // Left-click toggles the popover; right-click (or control-click) drops the context menu.
        // Both arrive through `statusButtonClicked`, which branches on the triggering event.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// A resizable rounded-rectangle mask so the `behindWindow` glass gets clean rounded corners
    /// (a plain layer corner-radius leaves the window-server-composited blur square at the edges).
    private static func roundedMaskImage(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
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
        panel.orderOut(nil)
        stopOutsideClickMonitors()
        statusItem.button?.highlight(false)
        anchorTopLeft = nil
        anchorScreen = nil
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

    /// Sizes the panel on show: the user's saved height (or a default), **clamped to fit the current
    /// screen**, with the top-left pinned under the status item. Width is fixed (single-column list).
    ///
    /// This is the whole cross-display story: we store ONE height. If it doesn't fit the screen the
    /// panel is opening on (e.g. saved big on a Studio Display, opened on a laptop), we shrink it to fit
    /// *for this open only* — the saved value is untouched, so it returns to full size back on the big
    /// screen. The clamp runs before the panel is visible, so it's instant. There's no content-driven
    /// resize, so switching screens never moves the window — only the user's drag does.
    private func applyPanelSize() {
        guard let anchorTopLeft else { return }
        let saved = PanelHeightStore.load() ?? Self.defaultPanelHeight
        let height = min(max(saved, Self.minPanelHeight), maxPanelHeight())
        let origin = NSPoint(x: anchorTopLeft.x, y: anchorTopLeft.y - height)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: height)), display: false)
        panel.invalidateShadow()
    }

    // MARK: - Grip resize

    private func beginGripResize() {
        gripStartHeight = panel.frame.height
    }

    /// Live grip drag. `distance` is how far the pointer has moved down from where the drag began (down =
    /// grow). We set the frame and then lay the content out **synchronously** before it's drawn, so the
    /// SwiftUI content never lags the window frame — which was the wobble.
    private func updateGripResize(by distance: CGFloat) {
        guard let anchorTopLeft else { return }
        let height = min(max(gripStartHeight + distance, Self.minPanelHeight), maxPanelHeight())
        let origin = NSPoint(x: anchorTopLeft.x, y: anchorTopLeft.y - height)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: height)), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.invalidateShadow()
    }

    private func endGripResize() {
        PanelHeightStore.save(panel.frame.height)
    }

    /// The tallest the panel may be on the current screen: the room below its pinned top edge, capped at
    /// 85% of the screen's usable height so it never dominates a large display.
    private func maxPanelHeight() -> CGFloat {
        guard let anchorTopLeft, let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame else {
            return Self.defaultPanelHeight
        }
        let roomBelowAnchor = anchorTopLeft.y - visible.minY - 8
        let aestheticCap = floor(visible.height * 0.85)
        return max(Self.minPanelHeight, min(roomBelowAnchor, aestheticCap))
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

/// Persists the user's chosen panel height across launches. Width is fixed (single-column list), so
/// only height is stored; it's clamped to the current screen on each open (see `applyPanelSize`).
private enum PanelHeightStore {
    private static let key = "openusage.panel.height"

    static func load() -> CGFloat? {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? CGFloat(value) : nil
    }

    static func save(_ height: CGFloat) {
        UserDefaults.standard.set(Double(height), forKey: key)
    }
}

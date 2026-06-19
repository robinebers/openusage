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
    /// Tracks the SwiftUI content's ideal size so the panel resizes to it (the dashboard animates its
    /// own height on mode switches). Replaces the `NSPopover` `preferredContentSize` auto-tracking.
    private var contentSizeObservation: NSKeyValueObservation?
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
    /// Panel top-left in screen coords, captured on show. The panel grows downward from here as the
    /// content animates its height, so the top edge stays pinned just under the status-item button.
    private var anchorTopLeft: NSPoint?

    /// One width across both densities (matches `DashboardView.popoverWidth`).
    private static let panelWidth: CGFloat = 320
    /// Gap between the menu bar and the panel's top edge.
    private static let topGap: CGFloat = 4
    /// Corner radius of the panel surface; tuned to read like a system menu-bar popover.
    private static let cornerRadius: CGFloat = 13

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
        // The panel tracks SwiftUI's preferred size, so the dashboard's animated height changes
        // (mode switches, content growth) resize the panel instead of clipping.
        hosting.sizingOptions = .preferredContentSize
        self.hostingController = hosting

        self.panel = MenuBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 400),
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
        host.layer?.cornerRadius = Self.cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        container.addSubview(glass)
        container.addSubview(solid, positioned: .above, relativeTo: glass)
        container.addSubview(host, positioned: .above, relativeTo: solid)
        glassBackdrop = glass
        solidBackdrop = solid

        // A plain container VC owns the backdrop; the hosting controller is its child so SwiftUI gets
        // a proper view-controller hierarchy. The panel itself is sized by `resizePanelToContent`.
        let rootVC = NSViewController()
        rootVC.view = container
        rootVC.addChild(hostingController)
        panel.contentViewController = rootVC

        contentSizeObservation = hostingController.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.resizePanelToContent() }
        }

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

    /// Re-renders the menu-bar strip whenever anything it reads changes (pins, live data, meter
    /// style, menu-bar style). `withObservationTracking` re-arms itself after every change.
    private func updateButtonImage() {
        let image = withObservationTracking {
            renderButtonImage()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateButtonImage()
            }
        }
        statusItem.button?.image = image
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
        togglePopover()
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
        anchorTopLeft = clampedTopLeft(below: buttonRectOnScreen, width: Self.panelWidth)
        resizePanelToContent()

        // `canBecomeKey` + `.nonactivatingPanel` makes this key without activating the app — no
        // activation race, so the dashboard receives keys on the first try.
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        startOutsideClickMonitors()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        stopOutsideClickMonitors()
        statusItem.button?.highlight(false)
        anchorTopLeft = nil
    }

    /// Resizes the panel to the SwiftUI content's ideal size, keeping the top edge pinned under the
    /// status-item button (macOS window origins are bottom-left, so the origin drops as height grows).
    private func resizePanelToContent() {
        let size = hostingController.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        let origin: NSPoint
        if let anchorTopLeft {
            origin = NSPoint(x: anchorTopLeft.x, y: anchorTopLeft.y - size.height)
        } else {
            origin = panel.frame.origin
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
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
                else { return }
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

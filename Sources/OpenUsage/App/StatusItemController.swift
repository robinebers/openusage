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
class MenuBarPanel: NSPanel {
    /// Corner radius of the panel surface; tuned to read like a system menu-bar popover.
    static let cornerRadius: CGFloat = 13

    /// A clear, borderless panel whose frame view is clipped to the rounded shape. The clip lives on
    /// the frame view, not the content view: AppKit inserts a sheet's dimming view as the content
    /// view's sibling, so only the frame view's mask keeps it inside the rounded corners.
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        guard let frameView = contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = Self.cornerRadius
        frameView.layer?.cornerCurve = .continuous
        frameView.layer?.masksToBounds = true
    }

    /// Closes the popover through its owner, the same path a status-item click takes; Esc on the
    /// dashboard calls it.
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A click on the panel while it isn't key (the app deactivated, or a menu or popover took key)
    /// makes it key first. Otherwise AppKit spends the click on making the panel key and the view under
    /// the pointer never sees it, so a double-click on a name reads as one click and opens no rename.
    override func sendEvent(_ event: NSEvent) {
        if !isKeyWindow, attachedSheet == nil,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            makeKey()
        }
        super.sendEvent(event)
    }
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
    private let statusItem: NSStatusItem
    private var stripGate = StripGate()
    private let panel: MenuBarPanel
    private let heightController: PanelHeightController
    private lazy var outsideClickMonitor = PanelOutsideClickMonitor(
        panel: panel,
        statusItem: statusItem,
        isMorphing: { [weak self] in self?.heightController.isMorphing ?? false },
        onInsidePanelClick: { [weak self] in self?.clearStrayFocus() },
        onDismiss: { [weak self] in self?.hidePanel() }
    )
    private let hostingController: NSHostingController<AnyView>

    init(container: AppContainer, updater: UpdaterController) {
        self.container = container
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        let hosting = NSHostingController(
            rootView: AnyView(
                DashboardView()
                    // Own the preference outside `DashboardView` so the view can read the resolved
                    // value while deciding whether to mount its two-page transition structure.
                    .reduceAnimationsWhenRequested()
                    .environment(container)
                    .environment(container.layout)
                    .environment(container.dataStore)
                    .environment(container.renaming)
                    .environment(container.popover)
                    .environment(updater)
            )
        )
        // The host view fills the panel. SwiftUI measures each screen and drives the panel height;
        // content scrolls only when that height reaches the available-screen limit.
        self.hostingController = hosting

        let panel = MenuBarPanel(contentRect: NSRect(
            x: 0,
            y: 0,
            width: PanelMetrics.width,
            height: PanelHeightController.defaultHeight
        ))
        self.panel = panel
        self.heightController = PanelHeightController(panel: panel) { container.popover.screen }

        super.init()

        configurePanel()
        configureStatusItem()
        updateImage()

        // Registered once here; the controller lives for the app's whole life.
        KeyboardShortcuts.onKeyUp(for: .togglePopover) { [weak self] in
            AppLog.info(.statusItem, "Global shortcut fired; toggling popover")
            self?.togglePopover()
        }

        // Esc on the dashboard dismisses through the same code path as a status-item click.
        panel.onDismiss = { [weak self] in
            self?.hidePanel()
        }
        // A tapped alert opens the dashboard, without toggling an open panel shut.
        AppNotifications.shared.registerAsDelegate { [weak self] in
            guard let self else { return }
            container.popover.screen = .dashboard
            if panel.isVisible {
                panel.makeKeyAndOrderFront(nil)
                statusItem.button?.highlight(true)
            } else {
                showPanel()
            }
        }

        heightController.installBridge()

        AppLog.info(.statusItem, "Status item ready (button: \(self.statusItem.button != nil), shortcut: \(KeyboardShortcuts.getShortcut(for: .togglePopover)?.description ?? "none"))")
    }

    // MARK: - Panel configuration

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The window paints an opaque tray so the data region never shows the desktop through it (Liquid
        // Glass stays reserved for the footer chrome, rendered in-window over this backing). It fills the
        // whole window, so a screen-switch resize can't reveal a transparent strip, and any region SwiftUI
        // leaves unpainted shows the tray, not a raw hole. `Theme.trayNSColor` tracks light/dark and the
        // forced appearance override, matching the SwiftUI tray (`DashboardView.PopoverSurface`).
        // `MenuBarPanel` clips everything to its rounded frame.
        panel.backgroundColor = Theme.trayNSColor
        let host = hostingController.view
        host.wantsLayer = true
        // Redraw the SwiftUI content on every step of a height change instead of stretching the layer's
        // cached contents (the default `.onSetNeedsDisplay`), which keeps cards steady during a morph.
        host.layerContentsRedrawPolicy = .duringViewResize
        // SwiftUI never sizes the window: panel placement and height live in `heightController`.
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusButtonClicked)
        // Left-click toggles the popover; right-click (or control-click) drops the context menu.
        // Both arrive through `statusButtonClicked`, which branches on the triggering event.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Menu-bar strip

    /// Shows a strip only when its content changed: setting even an identical image costs a full
    /// status-item redraw through WindowServer on macOS 26+.
    struct StripGate {
        private var shown: MenuBarContent?

        mutating func show(_ content: MenuBarContent, using show: (MenuBarContent) -> Void) {
            guard content != shown else { return }
            shown = content
            show(content)
        }
    }

    /// Renders the pinned-metrics strip, or the app icon when nothing is pinned, and re-renders whenever
    /// anything it reads changes (pins, live data, meter style, menu-bar style).
    ///
    /// `withObservationTracking`'s `onChange` is one-shot, so each render re-arms it. After a change, the
    /// next render waits briefly so a burst of snapshot writes collapses into one render with the latest
    /// values — avoiding enough repeated work to make the menu-bar item disappear during a busy refresh.
    private func updateImage() {
        let content = withObservationTracking {
            MenuBarContentBuilder.build(
                groups: container.layout.pinnedGroups,
                isStale: container.dataStore.hasStaleAccount,
                data: { container.dataStore.data(for: $0) }
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.updateImage()
            }
        }
        stripGate.show(content) { content in
            statusItem.button?.image = MenuBarStripRenderer.image(for: content)
                ?? MenuBarStripRenderer.appIcon(for: content)
        }
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

    /// Right-click / control-click on the status item: a native menu mirroring the Settings and Quit
    /// items in the popover footer's Options menu (same titles, symbols, and ⌘ shortcuts). Assigning
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
        container.popover.screen = .settings
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
        let buttonRectOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // Record the display before changing the visibility signal. That signal makes SwiftUI
        // immediately clamp the measured height; without the display anchor the clamp falls back to
        // the fixed opening guess, making large and small displays open at the same height.
        heightController.prepareForOpening(below: buttonRectOnScreen)
        // Mark the popover on-screen before laying out: `DashboardView` re-seeds its height on the flip.
        container.popover.popoverShown = true

        // Lay the content out first so the panel opens at the right size (no first-frame flash).
        hostingController.view.layoutSubtreeIfNeeded()

        // `canBecomeKey` + `.nonactivatingPanel` makes this key without activating the app — no
        // activation race, so the dashboard receives keys on the first try.
        panel.makeKeyAndOrderFront(nil)
        // Becoming key, AppKit auto-focuses the first control in the key-view loop (the first row's
        // Used/Left toggle) when system Keyboard Navigation is on — so the popover would open with a
        // stray focus ring nobody asked for. Drop it; keyboard nav still works (it rides a local key
        // monitor, not first responder), and Tab from here focuses the first control as expected.
        clearStrayFocus()
        button.highlight(true)
        outsideClickMonitor.start()
    }

    private func hidePanel() {
        // The popover's SwiftUI tree survives `orderOut`, so a tooltip the cursor was resting on gets
        // no hover-exit and would orphan on screen — clear it here, the one chokepoint every close hits.
        // Dismiss any auxiliary popover that would otherwise survive closing this panel.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        ReducedMotionPopoverController.dismissAll()
        // Same survival problem for keyboard focus: a clicked plain-styled control (a row's Used/Left
        // or reset toggle) stays first responder, so its focus ring would reopen with the popover as a
        // stray blue outline. Drop it on close so every reopen starts unfocused.
        clearStrayFocus()
        // Save while the closing screen is still current; the authoritative SwiftUI close reset runs
        // afterward.
        heightController.saveBeforeClosing()
        // The authoritative hide signal, flipped synchronously with `orderOut`.
        container.popover.popoverShown = false
        panel.orderOut(nil)
        outsideClickMonitor.stop()
        statusItem.button?.highlight(false)
        heightController.finishClosing()
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

}

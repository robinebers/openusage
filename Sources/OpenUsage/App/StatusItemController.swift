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
                    .reduceAnimationsWhenRequested()
                    .environment(container)
                    .environment(container.layout)
                    .environment(container.dataStore)
                    .environment(container.renaming)
                    .environment(container.popover)
                    .environment(updater)
            )
        )
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

        KeyboardShortcuts.onKeyUp(for: .togglePopover) { [weak self] in
            AppLog.info(.statusItem, "Global shortcut fired; toggling popover")
            self?.togglePopover()
        }

        panel.onDismiss = { [weak self] in
            self?.hidePanel()
        }
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

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.backgroundColor = Theme.trayNSColor
        let host = hostingController.view
        host.wantsLayer = true
        host.layerContentsRedrawPolicy = .duringViewResize
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusButtonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

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
        heightController.prepareForOpening(below: buttonRectOnScreen)
        container.popover.popoverShown = true

        hostingController.view.layoutSubtreeIfNeeded()

        panel.makeKeyAndOrderFront(nil)
        clearStrayFocus()
        button.highlight(true)
        outsideClickMonitor.start()
    }

    private func hidePanel() {
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        ReducedMotionPopoverController.dismissAll()
        clearStrayFocus()
        heightController.saveBeforeClosing()
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

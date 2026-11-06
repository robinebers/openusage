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
    static let cornerRadius: CGFloat = 20

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

    /// Hosts the dashboard one level below the content view. Under the SwiftUI App lifecycle a hosting
    /// view that is its window's content view resizes the window to its root size on every layout,
    /// whatever its `sizingOptions` (`animatesWindowRootSize`), which fought `PanelHeightController` for
    /// the frame until AppKit threw "more Update Constraints in Window passes than there are views".
    func host(_ view: NSHostingView<some View>) {
        guard let contentView else { return }
        view.sizingOptions = []
        view.layerContentsRedrawPolicy = .duringViewResize
        view.frame = contentView.bounds
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)
    }

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

    /// Settings stays mounted offscreen after its first visit, where its shortcut recorder is disabled.
    /// A disabled recorder still accepts focus, and then records the next key press as the global
    /// shortcut, so the panel refuses to focus it.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let recorder = responder as? KeyboardShortcuts.RecorderCocoa, !recorder.isEnabled { return false }
        return super.makeFirstResponder(responder)
    }

    /// Drops keyboard focus inside the panel so a clicked plain-styled control (a metric row's
    /// Used/Left + reset toggles) doesn't keep the system focus ring lingering as a stray outline:
    /// AppKit leaves the control first responder until focus moves, which a click on empty space or a
    /// close otherwise never does. Skips a live text field, whose focus is the user's intent, but not the
    /// shortcut recorder: AppKit can focus it without a click, and then it records the next key press.
    func clearStrayFocus() {
        let recording = (firstResponder as? NSTextView)?.delegate is KeyboardShortcuts.RecorderCocoa
        guard recording || !(firstResponder is NSText) else { return }
        makeFirstResponder(nil)
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
    private let updater: UpdaterController
    private let statusItem: NSStatusItem
    private var stripGate = StripGate()
    private var rankingTick: Task<Void, Never>?
    private let panel: MenuBarPanel
    private let heightController: PanelHeightController
    private lazy var outsideClickMonitor = PanelOutsideClickMonitor(
        panel: panel,
        statusItem: statusItem,
        isMorphing: { [weak self] in self?.heightController.isMorphing ?? false },
        onInsidePanelClick: { [weak self] in self?.panel.clearStrayFocus() },
        onDismiss: { [weak self] in self?.hidePanel() }
    )
    private let host: NSHostingView<AnyView>

    init(container: AppContainer, updater: UpdaterController) {
        self.container = container
        self.updater = updater
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        let host = NSHostingView(
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
        self.host = host

        let panel = MenuBarPanel(contentRect: NSRect(
            x: 0,
            y: 0,
            width: PanelMetrics.width,
            height: PanelHeightController.defaultHeight
        ))
        self.panel = panel
        self.heightController = PanelHeightController(
            panel: panel,
            currentScreen: { container.popover.screen },
            currentTab: { container.popover.dashboardTab }
        )

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
                container.popover.dashboardTab = .allUsage
                panel.makeKeyAndOrderFront(nil)
                statusItem.button?.highlight(true)
            } else {
                showPanel(dashboardTab: .allUsage)
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

        panel.host(host)
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
        let (accounts, pinned, burningFast, useItOrLoseIt, limit, alwaysShows, updateAvailable) = withObservationTracking {
            let limit = container.hideFromScreenShare.isConcealing ? .iconOnly : container.dataStore.menuBarLimit
            let accounts = limit == .iconOnly ? [] : container.dataStore.accounts(in: container.layout.displayGroups)
            return (accounts, container.layout.state.priorityPinIDs, container.dataStore.burningFast, container.dataStore.showsUseItOrLoseIt,
                    limit, container.dataStore.menuBarAlwaysShows, updater.availableUpdateVersion != nil)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                self?.updateImage()
            }
        }
        rankingTick?.cancel()
        showStrip(accounts: accounts, pinned: pinned, burningFast: burningFast, useItOrLoseIt: useItOrLoseIt, limit: limit,
                  alwaysShows: alwaysShows, updateAvailable: updateAvailable)
    }

    private func showStrip(
        accounts: [DashboardAccount], pinned: Set<String>, burningFast: BurningFast?, useItOrLoseIt: Bool, limit: MenuBarLimit,
        alwaysShows: Bool, updateAvailable: Bool
    ) {
        let now = Date()
        let board = PriorityBoard.make(accounts: accounts, pinned: pinned, burningFast: burningFast, useItOrLoseIt: useItOrLoseIt, now: now)
        var content = MenuBarContentBuilder.build(board: board, limit: limit, alwaysShows: alwaysShows)
        content.updateAvailable = updateAvailable
        stripGate.show(content) { content in
            statusItem.button?.image = MenuBarStripRenderer.image(for: content)
                ?? MenuBarStripRenderer.appIcon
        }
        // The pace order can change between provider reads. A tick only reuses the current data;
        // registering another observation here would multiply subscriptions on every tick.
        guard board.requiresRankingClock(at: now) else { return }
        rankingTick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30), tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.showStrip(accounts: accounts, pinned: pinned, burningFast: burningFast, useItOrLoseIt: useItOrLoseIt, limit: limit,
                            alwaysShows: alwaysShows, updateAvailable: updateAvailable)
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

    private func showPanel(dashboardTab: DashboardTab = .preferred()) {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            AppLog.error(.statusItem, "Cannot show panel: status item has no button")
            return
        }
        let buttonRectOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        heightController.prepareForOpening(below: buttonRectOnScreen, tab: dashboardTab)
        container.popover.show(dashboardTab: dashboardTab)

        host.layoutSubtreeIfNeeded()

        panel.makeKeyAndOrderFront(nil)
        panel.clearStrayFocus()
        button.highlight(true)
        outsideClickMonitor.start()
    }

    private func hidePanel() {
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        ReducedMotionPopoverController.dismissAll()
        panel.clearStrayFocus()
        heightController.saveBeforeClosing()
        container.popover.popoverShown = false
        panel.orderOut(nil)
        outsideClickMonitor.stop()
        statusItem.button?.highlight(false)
        heightController.finishClosing()
    }

}

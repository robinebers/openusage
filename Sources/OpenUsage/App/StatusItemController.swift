import AppKit
import KeyboardShortcuts
import SwiftUI

/// Owns the menu-bar status item and the popover that shows the dashboard.
///
/// This deliberately does not use SwiftUI's `MenuBarExtra`: its `.window` panel never becomes a
/// proper key window for text input (the Settings shortcut recorder silently ignored key presses)
/// and there is no public API to present it programmatically — the MenuBarExtraAccess bridge
/// drives a simulated status-item click that became a silent no-op on macOS 26+. A plain
/// `NSStatusItem` + `NSPopover` gives a real key window and a real `show()`/`performClose()` pair
/// the global shortcut can call directly.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let container: AppContainer
    private let updater: UpdaterController
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    /// Closes the popover on clicks outside it. `.transient` popover behavior is unreliable for
    /// accessory apps (the popover can swallow the first outside click or refuse to close), so the
    /// popover is `.applicationDefined` and this monitor implements "click away closes" itself.
    private var outsideClickMonitors: [Any] = []
    /// Token for the appearance-change observer. The center keeps block observers alive on its
    /// own, but holding the token follows the documented removal pattern (and the other observers
    /// in this codebase) should the controller ever stop living for the app's whole life.
    private var appearanceObserver: NSObjectProtocol?
    /// Re-asserts popover key focus when the app finally becomes active — the backstop for the
    /// macOS 26+ case where `NSApp.activate` lands past `makePopoverKey`'s retry window. See
    /// `makePopoverKey`.
    private var activationObserver: NSObjectProtocol?

    init(container: AppContainer, updater: UpdaterController) {
        self.container = container
        self.updater = updater
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        // The popover inherits its appearance from the positioning view — the status-bar button —
        // so the menu bar's appearance, not `NSApp.appearance`, would win. Pin the theme override
        // here (nil for System) and track the Settings picker live.
        popover.appearance = AppearanceSetting.current.nsAppearance
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSetting.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.popover.appearance = AppearanceSetting.current.nsAppearance
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.makePopoverKey(attempts: Self.makeKeyAttempts)
            }
        }
        let host = NSHostingController(
            rootView: DashboardView()
                .environment(container)
                .environment(container.layout)
                .environment(container.dataStore)
                .environment(updater)
        )
        // The popover tracks SwiftUI's preferred size, so the dashboard's animated height changes
        // (mode switches, content growth) resize the popover instead of clipping.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked)
        }

        updateButtonImage()

        // Registered once here; the controller lives for the app's whole life.
        KeyboardShortcuts.onKeyUp(for: .togglePopover) { [weak self] in
            AppLog.info(.statusItem, "Global shortcut fired; toggling popover")
            self?.togglePopover()
        }

        // Esc on the dashboard (and the footer's close affordances) dismiss through the same
        // code path as a status-item click.
        MenuBarPopover.dismissHandler = { [weak self] in
            self?.closePopover()
        }

        AppLog.info(.statusItem, "Status item ready (button: \(self.statusItem.button != nil), shortcut: \(KeyboardShortcuts.getShortcut(for: .togglePopover)?.description ?? "none"))")
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

    // MARK: - Popover

    @objc private func statusButtonClicked() {
        togglePopover()
    }

    func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else {
            AppLog.error(.statusItem, "Cannot show popover: status item has no button")
            return
        }
        // An inactive accessory app receives no keyboard input — without activation the popover looks
        // focused but Esc/Return navigation and the shortcut recorder are dead.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        startOutsideClickMonitors()
        makePopoverKey(attempts: Self.makeKeyAttempts)
    }

    /// Drives the popover window to key so it actually receives keystrokes. Activating an accessory
    /// app via `NSApp.activate` is asynchronous and, on macOS 26+, can lag several runloop ticks or be
    /// denied outright — and a window can't be key while its app is inactive, so a single `makeKey()`
    /// after `show` often leaves the popover non-key (its Esc/Return navigation and the shortcut
    /// recorder dead until a second click). So retry across a few ticks until the window is key; the
    /// `didBecomeActiveNotification` observer in `init` is the backstop for activation that lands later
    /// still. (Pattern verified via GitHits across several menu-bar apps — e.g. SpacePill, Stats.)
    private static let makeKeyAttempts = 12
    private func makePopoverKey(attempts: Int) {
        guard popover.isShown,
              let window = popover.contentViewController?.view.window else { return }
        window.makeKey()
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        if window.isKeyWindow { return }
        guard attempts > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            self?.makePopoverKey(attempts: attempts - 1)
        }
    }

    /// While the popover is up, `animates` must stay off: with it on, every SwiftUI-driven
    /// `preferredContentSize` update (the dashboard animates its height frame-by-frame on mode
    /// switches) starts a fresh implicit popover resize animation, and the window lags and
    /// rubber-bands behind the content. Off, the window tracks SwiftUI's animation exactly.
    /// Show/close keep the system fade by flipping `animates` back on around them.
    func popoverDidShow(_ notification: Notification) {
        popover.animates = false
    }

    private func closePopover() {
        popover.animates = true
        popover.performClose(nil)
    }

    func popoverWillClose(_ notification: Notification) {
        stopOutsideClickMonitors()
        statusItem.button?.highlight(false)
    }

    // MARK: - Outside-click dismissal

    private func startOutsideClickMonitors() {
        stopOutsideClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // NSEvent is not Sendable: pull the window identity and location out before hopping
            // to the actor. With no window, the location is already in screen coordinates.
            let windowID = event.window.map(ObjectIdentifier.init)
            let windowTypeName = event.window.map { String(describing: type(of: $0)) }
            let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            MainActor.assumeIsolated {
                guard let self,
                      !self.shouldKeepPopoverOpen(windowID: windowID, windowTypeName: windowTypeName, screenPoint: screenPoint)
                else { return }
                self.closePopover()
            }
            return event
        }) {
            outsideClickMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // Global monitor events carry no window; the location is in screen coordinates.
            let screenPoint = event.locationInWindow
            Task { @MainActor [weak self] in
                guard let self, !self.isOnStatusButton(screenPoint: screenPoint) else { return }
                self.closePopover()
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

    /// In-app clicks that must not dismiss: anything inside the popover itself, the status-item
    /// button (its own handler toggles — closing here too would cancel it out and reopen), and
    /// menu windows (the Settings pickers' popup menus render in separate `NSMenu`-backed
    /// windows). Status-item clicks can arrive with no window (the menu bar is composited by the
    /// Window Server), so the button is also matched by screen position.
    private func shouldKeepPopoverOpen(windowID: ObjectIdentifier?, windowTypeName: String?, screenPoint: NSPoint) -> Bool {
        if isOnStatusButton(screenPoint: screenPoint) { return true }
        guard let windowID, let windowTypeName else { return false }
        if let popoverWindow = popover.contentViewController?.view.window,
           windowID == ObjectIdentifier(popoverWindow) {
            return true
        }
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

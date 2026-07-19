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
    private let statusItem: NSStatusItem
    /// Owns the menu-bar strip render loop. Its apply closure captures the `NSStatusItem` directly
    /// (which never retains the controller), so this can be a plain non-optional `let`.
    private let imageUpdater: StatusItemImageUpdater
    private let panel: MenuBarPanel
    private let heightController: PanelHeightController
    private lazy var outsideClickMonitor = PanelOutsideClickMonitor(
        panel: panel,
        statusItem: statusItem,
        isMorphing: { [weak self] in self?.heightController.isMorphing ?? false },
        onInsidePanelClick: { [weak self] in self?.clearStrayFocus() },
        onDismiss: { [weak self] in self?.hidePanel() }
    )
    /// Keeps the app reachable when the menu bar overflows and macOS parks the status item under
    /// the notch: first tries to move the item back into the visible menu bar, and if that doesn't
    /// stick, shows a surrogate pill at the nearest visible notch edge that opens the dashboard.
    private lazy var occlusionMonitor = StatusItemOcclusionMonitor(
        statusItem: statusItem,
        onActivate: { [weak self] in
            self?.container.layout.screen = .dashboard
            self?.showPopover()
        },
        onRescue: { [weak self] _ in
            self?.repositionStatusItemRightOfNotch()
        }
    )
    private let hostingController: NSHostingController<AnyView>
    /// The panel's backdrop: an opaque tray by default, swapped to a behind-window vibrancy view when
    /// the transparency style is non-opaque. Built once and toggled, so it can't race the style observer.
    private let backdrop = PopoverBackdropView(cornerRadius: StatusItemController.cornerRadius)
    /// Token for the appearance-change observer; held to follow the documented removal pattern.
    private var appearanceObserver: NSObjectProtocol?
    /// Corner radius of the panel surface; tuned to read like a system menu-bar popover.
    private static let cornerRadius: CGFloat = 13

    init(container: AppContainer, updater: UpdaterController) {
        self.container = container
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        // Captures the status item, not `self` — no retain cycle, and no optional property just to
        // work around `[weak self]` being unavailable before `super.init()`. The button is resolved
        // lazily at each apply, so a not-yet-configured button is harmless (same as before the split).
        self.imageUpdater = StatusItemImageUpdater(container: container) { image in
            statusItem.button?.image = image
        }

        let hosting = NSHostingController(
            rootView: AnyView(
                DashboardView()
                    .environment(container)
                    .environment(container.layout)
                    .environment(container.dataStore)
                    .environment(container.transparency)
                    .environment(updater)
                    .environment(\.codexResetClaim, container.codexResetClaim)
            )
        )
        // The host view fills the panel. SwiftUI measures each screen and drives the panel height;
        // content scrolls only when that height reaches the available-screen limit.
        self.hostingController = hosting

        let panel = MenuBarPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PanelHeightController.panelWidth,
                height: PanelHeightController.defaultHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        self.heightController = PanelHeightController(panel: panel) { container.layout.screen }

        super.init()

        configurePanel()
        configureStatusItem()
        imageUpdater.update()
        applyTransparency()

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

        // Esc on the dashboard dismisses through the same code path as a status-item click.
        MenuBarPopover.dismissHandler = { [weak self] in
            self?.hidePanel()
        }
        MenuBarPopover.showHandler = { [weak self] in
            self?.container.layout.screen = .dashboard
            self?.showPopover()
        }

        heightController.installBridge()
        if NotchGeometry.fallbackIsNeeded {
            occlusionMonitor.start()
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

        // Backdrop: by default an opaque tray so the data region never shows the desktop through it
        // (Liquid Glass stays reserved for the footer chrome, rendered in-window over this backing). The
        // `PopoverBackdropView` also holds a behind-window vibrancy layer that the transparency style
        // swaps in for Increase Transparency / the secret-code egg. It fills the whole window, so a
        // screen-switch resize can't reveal a transparent strip, and any region SwiftUI leaves unpainted
        // shows the backdrop, not a raw hole. Its opaque tray is `Theme.trayNSColor` (tracks light/dark
        // and the forced appearance override) matching the SwiftUI tray (`DashboardView.PopoverSurface`),
        // rounded via `cornerRadius`. `panel.appearance` (tracked by `appearanceObserver`) pins the mode.
        let host = hostingController.view
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        // Redraw the SwiftUI content on every step of a height change instead of stretching the layer's
        // cached contents (the default `.onSetNeedsDisplay`), which keeps cards steady during a morph.
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
        // a proper view-controller hierarchy. Panel placement and height live in `heightController`.
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

    /// Moves a notch-hidden status item back into the visible menu bar by rewriting its preferred
    /// position — the same defaults key macOS maintains when the user ⌘-drags the item — and
    /// re-adding the item so AppKit reads it. The key is undocumented but long-stable (it is how
    /// every status item's position persists across launches); if a macOS release stops honoring
    /// it, the occlusion monitor's re-measure simply falls back to the surrogate pill.
    ///
    /// The menu bar is zero-sum: landing right of the notch shifts a neighbor leftward. That is the
    /// deliberate trade — the user is interacting with OpenUsage, and the displaced neighbor is
    /// whatever macOS was about to hide anyway when space next runs out.
    private func repositionStatusItemRightOfNotch() {
        guard
            let button = statusItem.button,
            let window = button.window,
            let screen = window.screen,
            let notch = NotchGeometry.notchRect(of: screen)
        else { return }
        let itemWidth = max(button.bounds.width, 24)
        // Preferred position ≈ distance from the screen's right edge to the item's right edge.
        // Target: the item's left edge lands just right of the notch.
        let offset = screen.frame.maxX - notch.maxX - itemWidth - 12
        guard offset > 0 else { return }
        // `autosaveName` is an IUO; interpolating it directly would write a key literally named
        // "… Optional(\"Item-0\")" that AppKit never reads.
        guard let name = statusItem.autosaveName else { return }
        UserDefaults.standard.set(
            Double(offset),
            forKey: "NSStatusItem Preferred Position \(name)"
        )
        // AppKit only reads a preferred position when an autosave name is assigned (toggling
        // `isVisible` re-adds the item at its old spot). Bounce through a scratch name and back:
        // assigning the original name again makes AppKit look up — and move to — the position
        // just written. The scratch key is removed so it can't shadow anything later.
        statusItem.autosaveName = "\(name).rescue"
        statusItem.autosaveName = name
        UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(name).rescue")
        // The bounce can rebuild the button; re-attach click handling and repaint the strip.
        configureStatusItem()
        imageUpdater.update()
        AppLog.warn(
            .statusItem,
            "Status item was behind the notch; repositioned to \(Int(offset))pt from the right edge"
        )
    }

    // MARK: - Transparency

    /// True once the launch application has run, so subsequent style changes animate (the first one
    /// shouldn't fade in from nothing).
    private var hasAppliedTransparency = false

    /// Applies the resolved transparency style to the panel and re-arms on the next change. Mirrors
    /// `StatusItemImageUpdater.update()`'s `withObservationTracking` re-arm (its `onChange` is
    /// one-shot). Reads the
    /// store's `effectiveStyle`, which folds in the persisted toggle, the egg state, and the system
    /// accessibility flags — so this fires whenever any of them changes. Backdrop already exists (it's a
    /// stored property), so the first call from `init` safely sets the initial look.
    ///
    /// On every change after launch the window alpha and the backdrop crossfade ease together in one
    /// ~0.55s group, matching the SwiftUI side (`tooMuchTransparency`'s `.animation`), so toggling the
    /// egg or Increase Transparency fades in and out instead of snapping.
    private func applyTransparency() {
        let style = withObservationTracking {
            container.transparency.effectiveStyle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyTransparency()
            }
        }
        let mode: PopoverBackdropView.Mode = style.surfaceTreatment == .opaque ? .opaque : .translucent
        if hasAppliedTransparency {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.55
                context.allowsImplicitAnimation = true
                panel.animator().alphaValue = style.windowAlpha
                backdrop.setMode(mode, animated: true)
            }
        } else {
            hasAppliedTransparency = true
            panel.alphaValue = style.windowAlpha
            backdrop.setMode(mode, animated: false)
        }
        // Shadow isn't animatable; set it directly (the crossfade masks the change).
        panel.hasShadow = style.wantsShadow
        panel.invalidateShadow()
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

    /// Opens the dashboard panel without toggling it shut when already visible — used when an external
    /// trigger (a tapped pace notification) should surface the popover.
    func showPopover() {
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            statusItem.button?.highlight(true)
            return
        }
        showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            AppLog.error(.statusItem, "Cannot show panel: status item has no button")
            return
        }
        let buttonRectOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // A button parked under the notch is no anchor: the panel would open centered below the
        // notch, seemingly out of nowhere. Anchor at the nearest visible notch edge instead.
        var anchorRect = buttonRectOnScreen
        if NotchGeometry.fallbackIsNeeded,
           let screen = buttonWindow.screen,
           let notch = NotchGeometry.notchRect(of: screen),
           let occlusion = NotchGeometry.occlusion(of: buttonRectOnScreen, notch: notch),
           occlusion.isEffectivelyHidden {
            anchorRect = NotchGeometry.panelAnchorRect(
                for: occlusion,
                buttonRect: buttonRectOnScreen,
                panelWidth: PanelHeightController.panelWidth
            )
            AppLog.warn(.statusItem, "Status item is behind the notch; anchoring the panel at x=\(Int(anchorRect.minX))")
        }
        // The pill and the panel share the same anchor; showing both stacks them.
        occlusionMonitor.setSuppressed(true)
        // Record the display before changing the visibility signal. That signal makes SwiftUI
        // immediately clamp the measured height; without the display anchor the clamp falls back to
        // the fixed opening guess, making large and small displays open at the same height.
        heightController.prepareForOpening(below: anchorRect)
        // Mark the popover on-screen before laying out, so the egg's animation loops mount their
        // `TimelineView` clocks in time for the first displayed frame. Read by the SwiftUI egg via
        // `\.popoverIsVisible`; a closed popover keeps the loops unmounted, so a left-on egg costs no CPU.
        container.transparency.setPopoverShown(true)

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
        // The Usage Trend hover popover is on the same survives-orderOut footing, so dismiss it too.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        // Same survival problem for keyboard focus: a clicked plain-styled control (a row's Used/Left
        // or reset toggle) stays first responder, so its focus ring would reopen with the popover as a
        // stray blue outline. Drop it on close so every reopen starts unfocused.
        clearStrayFocus()
        // Save while the closing screen is still current; the authoritative SwiftUI close reset runs
        // afterward.
        heightController.saveBeforeClosing()
        // Closing: drop the on-screen flag so the egg's animation loops unmount their `TimelineView`
        // clocks and stop ticking — the whole point of the gate (no CPU while the egg is left on but the
        // popover is hidden). This is the authoritative hide signal, flipped synchronously with `orderOut`.
        container.transparency.setPopoverShown(false)
        panel.orderOut(nil)
        outsideClickMonitor.stop()
        statusItem.button?.highlight(false)
        heightController.finishClosing()
        // Re-evaluate occlusion now that the panel is gone (brings the pill back if still hidden).
        occlusionMonitor.setSuppressed(false)
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

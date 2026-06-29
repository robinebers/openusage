import SwiftUI
import AppKit

/// Reports whether the hosting menu-bar popover is actually present (ordered-on), so the dashboard can
/// reset its transient UI state when the popover genuinely goes away.
///
/// Why this signal and not key/focus: the popover keeps its SwiftUI view tree alive across open/close,
/// so transient UI state (edit mode, the add-widget gallery, scroll position) would otherwise persist
/// and reopen "stuck". We need a signal for "the popover went away" that does NOT fire when the user
/// merely clicks a control inside it. Key/resign-key fires on those clicks (breaking buttons), so it's
/// out.
///
/// Why it reports `window.isVisible` rather than the occlusion state: a `.canJoinAllSpaces` panel that
/// is open while the user switches macOS Spaces stays ordered-on (it follows them), but it is fully
/// *occluded* during the Space transition, so `occlusionState` drops `.visible` and then regains it.
/// Reporting occlusion directly mistook that for a dismissal and reset the still-open popover mid-switch
/// — which blanked the scroll content (the reset scrolls to top, drops the driven height, and resets the
/// screen) while the pinned chrome and the egg's gradient, living outside that subtree, kept rendering.
/// `isVisible` is true the whole time the panel is ordered-on (across Space switches and partial
/// occlusion) and flips to false only on a real `orderOut`, which is exactly the reset moment. Two
/// notifications wake the read — occlusion (open, close, Space switches) and the window becoming key
/// (every `makeKeyAndOrderFront`, which is the one that catches the *first* show; see `VisibilityView`)
/// — but the *value* reported is always `isVisible`, so a Space switch never reads as "gone".
struct PopoverVisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

    /// What wakes the `isVisible` read. Occlusion alone misses the first show (a freshly-created panel's
    /// `occlusionState` already contains `.visible`, so the first `makeKeyAndOrderFront` posts no change),
    /// so becoming key — which every open fires — is observed too. Both must stay present, or the egg
    /// animations freeze on first activation until a close-and-reopen (guarded by a test).
    static let visibilityTriggers: [NSNotification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didBecomeKeyNotification
    ]

    func makeNSView(context: Context) -> NSView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? VisibilityView)?.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastVisible: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else {
                report(false)
                return
            }
            // Two triggers, because neither alone catches every transition. The value reported is always
            // `window.isVisible` (true whenever the panel is ordered-on, false only on a real `orderOut`);
            // `isVisible` itself isn't KVO-compliant, so these notifications are the wake-up.
            //
            // - Occlusion fires on close, Space switches, and being covered — but NOT on the very first
            //   show: a freshly-created panel's `occlusionState` already contains `.visible`, so the first
            //   `makeKeyAndOrderFront` posts no *change*. Relying on it alone left the popover reporting
            //   its launch-time `isVisible == false` until a close-and-reopen finally toggled occlusion —
            //   which froze the easter-egg animations (paused via `\.popoverIsVisible`) on first activation.
            // - Becoming key fires on every `makeKeyAndOrderFront`, and every open goes through one, so it
            //   reliably catches that first show. We observe become-key but deliberately NOT resign-key: a
            //   panel that resigns key (a click in another app, a tracking menu) is still ordered-on and
            //   visible, and resign-key also fires on in-popover control clicks — the exact reason this
            //   reader avoids key/focus for its value. Reporting only `true` here can't misfire a
            //   dismissal (that rides a `false` from `orderOut`); it just fills the gap occlusion leaves.
            for name in PopoverVisibilityReader.visibilityTriggers {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        self?.report(window?.isVisible ?? false)
                    }
                })
            }
            report(window.isVisible)
        }

        private func report(_ visible: Bool) {
            guard lastVisible != visible else { return }
            lastVisible = visible
            onChange?(visible)
        }
    }
}

/// Handles the popover's two bare navigation keys via a local key monitor. SwiftUI
/// `.keyboardShortcut` is unreliable here — a hidden/zero-size shortcut button never registers, and
/// even a visible default button only fires when the popover is the key window — so the popover's
/// keyboard navigation rides this low-level monitor instead, which sees the raw keyDown the moment
/// the app processes it.
///
/// - **Esc**: `onEscape` gets first refusal (e.g. backing out of Customize); when it declines, the
///   popover is dismissed through `MenuBarPopover.dismiss`, the same path a status-item click takes
///   — so it stays in sync, reopens in one click, and trips the visibility reset (cancelling edit
///   mode + the jiggle).
/// - **Return**: `onReturn` opens/closes Customize (the same affordance the footer's Customize
///   button carries). Consuming the key here is also what stops a bare
///   Return from falling through and dismissing the popover.
struct PopoverKeyReader: NSViewRepresentable {
    /// Called first on Esc. Return `true` when the press was handled in-popover (Esc then does
    /// NOT close); return `false` to let the popover dismiss.
    var onEscape: @MainActor () -> Bool = { false }
    /// Called on plain (unmodified) Return. Return `true` to consume it (e.g. toggling Customize);
    /// `false` lets the key fall through to a focused control.
    var onReturn: @MainActor () -> Bool = { false }
    /// Called on ⌘, (Settings). Handled on this always-on monitor — the same one as Esc/Return — so it
    /// works from every screen, including Settings, which has no footer to host a SwiftUI shortcut. The
    /// More menu's Settings item carries ⌘, only as a *label*: while that menu is open the item handles
    /// it, while it's closed this monitor does, so they never both fire.
    var onSettings: @MainActor () -> Bool = { false }
    /// Called on plain ⌘Z (undo). Rides this monitor — same reasons as Esc/Return: a hidden SwiftUI
    /// shortcut only fires when the popover is the key window, which the panel isn't always for. By the
    /// time this runs the monitor has already confirmed the panel owns the keystroke and no text field is
    /// editing (those keep their own ⌘Z), so callers should return `true` and consume it whether or not an
    /// undo happened — returning `false` only lets AppKit beep on an empty undo.
    var onUndo: @MainActor () -> Bool = { false }

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onEscape = onEscape
        view.onReturn = onReturn
        view.onSettings = onSettings
        view.onUndo = onUndo
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.onEscape = onEscape
        view.onReturn = onReturn
        view.onSettings = onSettings
        view.onUndo = onUndo
    }

    /// Whether a bare-key keyDown belongs to the popover: its key window must *be* the panel. The
    /// panel is a non-activating key window that takes focus the instant it opens, so a foreign key
    /// window (an open About panel, a tracking `NSMenu` from the More menu or a Settings picker) — or
    /// no key window at all — is correctly *not* the popover's, and Esc/Return leave it alone instead
    /// of hijacking it. (An earlier build also claimed a nil key window, to paper over `NSPopover`'s
    /// activation race; the `NSPanel` removed that race, so the strict match is correct and safer.)
    // `nonisolated`: a pure comparison of two Sendable `ObjectIdentifier`s. The enclosing struct is
    // implicitly @MainActor (it stores @MainActor closures), which would otherwise wall this helper off
    // from non-MainActor callers — including its own tests (3 verified [#ActorIsolatedCall] warnings).
    nonisolated static func keyTargetsPopover(eventWindowID: ObjectIdentifier?, popoverWindowID: ObjectIdentifier) -> Bool {
        eventWindowID == popoverWindowID
    }

    final class MonitorView: NSView {
        var onEscape: (@MainActor () -> Bool)?
        var onReturn: (@MainActor () -> Bool)?
        var onSettings: (@MainActor () -> Bool)?
        var onUndo: (@MainActor () -> Bool)?
        private var monitor: Any?
        private static let escapeKeyCode: UInt16 = 53
        private static let returnKeyCode: UInt16 = 36
        private static let commaKeyCode: UInt16 = 43
        private static let zKeyCode: UInt16 = 6

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let keyCode = event.keyCode
                guard keyCode == MonitorView.escapeKeyCode
                    || keyCode == MonitorView.returnKeyCode
                    || keyCode == MonitorView.commaKeyCode
                    || keyCode == MonitorView.zKeyCode else {
                    return event
                }
                let isReturn = keyCode == MonitorView.returnKeyCode
                let isComma = keyCode == MonitorView.commaKeyCode
                let isUndo = keyCode == MonitorView.zKeyCode
                // Only bare Return navigates; ⌘⏎, ⌥⏎, etc. belong to other controls.
                if isReturn,
                   !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                    return event
                }
                // Only plain ⌘, navigates; a bare comma (typing) or ⌥⌘, etc. belong elsewhere.
                if isComma,
                   event.modifierFlags.intersection([.command, .option, .control, .shift]) != [.command] {
                    return event
                }
                // Only plain ⌘Z undoes; a bare z (typing) or ⇧⌘Z (redo) belong elsewhere.
                if isUndo,
                   event.modifierFlags.intersection([.command, .option, .control, .shift]) != [.command] {
                    return event
                }
                let eventWindowID = event.window.map(ObjectIdentifier.init)
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    // Only act while the popover is on-screen; the SwiftUI tree (and this monitor) can
                    // outlive a close, and `isVisible` stands in for `NSPopover.isShown`.
                    guard let self, let window = self.window, window.isVisible else { return false }
                    // The key must target the popover — its key window must be the panel, so a key
                    // pressed while a menu / About panel owns focus is left alone (see `keyTargetsPopover`).
                    // This is also what hands ⌘, to an open More menu's own item instead of here.
                    guard PopoverKeyReader.keyTargetsPopover(
                        eventWindowID: eventWindowID,
                        popoverWindowID: ObjectIdentifier(window)
                    ) else { return false }
                    // A text control is editing, or the Settings shortcut recorder is capturing a
                    // combo: the key belongs to it (insert / cancel / record), not to popover nav.
                    if window.firstResponder is NSText || ShortcutRecorderField.isRecordingActive {
                        return false
                    }
                    if isComma {
                        return self.onSettings?() ?? false
                    }
                    if isUndo {
                        return self.onUndo?() ?? false
                    }
                    if isReturn {
                        return self.onReturn?() ?? false
                    }
                    if self.onEscape?() == true {
                        return true
                    }
                    MenuBarPopover.dismiss(fallback: window)
                    return true
                }
                return consumed ? nil : event
            }
        }
    }
}

/// Lets views inside the popover close it without knowing who owns it.
@MainActor
enum MenuBarPopover {
    /// Installed by `StatusItemController` at launch; closes the popover through the same code
    /// path as a status-item click.
    static var dismissHandler: (() -> Void)?

    /// Auto-resize bridge — the "single clock". SwiftUI owns the animated height and the AppKit panel
    /// is a passive follower: `applyHeight` is called once per animation frame from a SwiftUI
    /// `Animatable` modifier with the interpolated height, and the controller hops it onto the main
    /// queue (mandatory — it's invoked from inside SwiftUI's layout pass, and `setFrame` re-enters
    /// AppKit layout on the constraint-pinned host, which would trip `_NSDetectedLayoutRecursion`) and
    /// `setFrame`s the panel. `clampHeight` lets SwiftUI clamp its target to the same [min, screen-max]
    /// range the panel will actually sit at, so the spring settles exactly on-frame.
    static var applyHeight: ((CGFloat) -> Void)?
    static var clampHeight: ((CGFloat) -> CGFloat)?

    /// Closes the popover. Falls back to ordering the given window out if no owner has installed
    /// a handler (which would be a wiring bug, so it's logged loudly by the caller's absence of
    /// effect rather than silently swallowed here).
    static func dismiss(fallback window: NSWindow?) {
        if let dismissHandler {
            dismissHandler()
        } else {
            window?.orderOut(nil)
        }
    }
}

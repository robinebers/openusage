import SwiftUI
import AppKit

/// Reports whether the hosting menu-bar popover is actually on-screen, via the window's occlusion
/// state.
///
/// Why occlusion and not key/focus: the popover keeps its SwiftUI view tree alive across
/// open/close, so transient UI state (edit mode, the add-widget gallery) would otherwise
/// persist and reopen "stuck". We need a signal for "the popover went away" — but it must NOT fire
/// when the user merely clicks a control inside the popover. Key/resign-key fires on those clicks
/// (breaking buttons); occlusion does not. Occlusion flips to not-`visible` when the popover is
/// dismissed (its window orders out), which is exactly the moment we want to reset.
struct PopoverVisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

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
        private var observer: NSObjectProtocol?
        private var lastVisible: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else {
                report(false)
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    self?.report(window?.occlusionState.contains(.visible) ?? false)
                }
            }
            report(window.occlusionState.contains(.visible))
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

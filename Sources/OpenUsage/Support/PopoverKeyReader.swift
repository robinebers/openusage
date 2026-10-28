import SwiftUI
import AppKit

/// Handles the popover's two bare navigation keys via a local key monitor. SwiftUI
/// `.keyboardShortcut` is unreliable here — a hidden/zero-size shortcut button never registers, and
/// even a visible default button only fires when the popover is the key window — so the popover's
/// keyboard navigation rides this low-level monitor instead, which sees the raw keyDown the moment
/// the app processes it.
///
/// - **Esc**: `onEscape` gets first refusal (e.g. backing out of Accounts); when it declines, the
///   panel's `onDismiss` closes the popover, the same path a status-item click takes — so it stays
///   in sync, reopens in one click, and trips the controller's visibility reset.
/// - **Return**: `onReturn` navigates into or back out of Accounts (the same affordance the footer's
///   Options ▸ Accounts item carries). Consuming the key here is also what stops a bare
///   Return from falling through and dismissing the popover.
///
/// None of these act while a text field is editing (an inline account rename, a sign-in field): the
/// key goes to the field, so Return commits and Esc cancels there instead.
struct PopoverKeyReader: NSViewRepresentable {
    /// Called first on Esc. Return `true` when the press was handled in-popover (Esc then does
    /// NOT close); return `false` to let the popover dismiss.
    var onEscape: @MainActor () -> Bool = { false }
    /// Called on plain (unmodified) Return. Return `true` to consume it (e.g. toggling Accounts);
    /// `false` lets the key fall through to a focused control.
    var onReturn: @MainActor () -> Bool = { false }
    /// Called on ⌘, (Settings). Handled on this always-on monitor — the same one as Esc/Return — so it
    /// works from every screen, including Settings, whose footer has no Settings action. The Options
    /// menu's Settings item carries ⌘, only as a *label*: while that menu is open the item handles
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
        view.reader = self
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.reader = self
    }

    final class MonitorView: NSView {
        var reader: PopoverKeyReader?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Esc with any modifiers; only bare Return (⌘⏎, ⌥⏎ belong to other controls); only plain
                // ⌘, and ⌘Z (a bare comma or z is typing, ⇧⌘Z is redo).
                let handler: KeyPath<PopoverKeyReader, @MainActor () -> Bool>
                switch (event.keyCode, event.modifierFlags.intersection([.command, .option, .control, .shift])) {
                case (53, _): handler = \.onEscape
                case (36, []): handler = \.onReturn
                case (43, [.command]): handler = \.onSettings
                case (6, [.command]): handler = \.onUndo
                default: return event
                }
                let eventWindow = event.window
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    // Only act while the popover is on-screen; the SwiftUI tree (and this monitor) can
                    // outlive a close, and `isVisible` stands in for `NSPopover.isShown`.
                    guard let self, let reader = self.reader, let window = self.window, window.isVisible else { return false }
                    // The key must target the popover: its key window must be the panel, so a key
                    // pressed while a menu / About panel owns focus (or no window is key) is left alone.
                    // This is also what hands ⌘, to an open Options menu's own item instead of here.
                    guard eventWindow === window else { return false }
                    // A text control is editing, or the Settings shortcut recorder is capturing a
                    // combo: the key belongs to it (insert / cancel / record), not to popover nav.
                    if window.firstResponder is NSText || ShortcutRecorderField.isRecordingActive {
                        return false
                    }
                    if reader[keyPath: handler]() { return true }
                    guard handler == \.onEscape else { return false }
                    (window as? MenuBarPanel)?.onDismiss?()
                    return true
                }
                return consumed ? nil : event
            }
        }
    }
}

/// The height bridge between the popover's SwiftUI content and the panel that hosts it.
@MainActor
enum MenuBarPopover {
    /// Auto-resize bridge — the "single clock". SwiftUI owns the animated height and the AppKit panel
    /// is a passive follower: `applyHeight` is called once per animation frame from a SwiftUI
    /// `Animatable` modifier with the interpolated height, and the controller hops it onto the main
    /// queue (mandatory — it's invoked from inside SwiftUI's layout pass, and `setFrame` re-enters
    /// AppKit layout on the constraint-pinned host, which would trip `_NSDetectedLayoutRecursion`) and
    /// `setFrame`s the panel. `clampHeight` lets SwiftUI clamp its target to the same [min, screen-max]
    /// range the panel will actually sit at, so the spring settles exactly on-frame.
    static var applyHeight: ((CGFloat) -> Void)?
    static var clampHeight: ((CGFloat) -> CGFloat)?
}

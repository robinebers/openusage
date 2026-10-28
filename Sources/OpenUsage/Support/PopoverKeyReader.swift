import SwiftUI
import AppKit

/// A key the popover's monitor hands to `PopoverKeyReader.onKey`.
enum PopoverKey {
    /// Esc, with any modifiers.
    case escape
    /// Bare Return; ⌘⏎, ⌥⏎ and the like belong to other controls.
    case `return`
    /// Plain ⌘, (Settings). The Options menu's Settings item carries ⌘, only as a *label*: while that
    /// menu is open the item handles it, while it's closed this monitor does, so they never both fire.
    case settings
    /// Plain ⌘Z (undo); ⇧⌘Z is redo and a bare z is typing.
    case undo
}

/// Handles the popover's navigation keys via a local key monitor. SwiftUI `.keyboardShortcut` is
/// unreliable here — a hidden/zero-size shortcut button never registers, and even a visible default
/// button only fires when the popover is the key window — so the popover's keyboard navigation rides
/// this low-level monitor instead, which sees the raw keyDown the moment the app processes it.
///
/// `onKey` returns `true` when it handled the key. Esc it declines closes the popover through the
/// panel's `onDismiss`, the same path a status-item click takes — so it stays in sync, reopens in one
/// click, and trips the controller's visibility reset; any other key it declines falls through.
///
/// None of these act while a text field is editing (an inline account rename, a sign-in field) or the
/// Settings shortcut recorder is capturing: the key goes to the field, so Return commits and Esc
/// cancels there instead.
struct PopoverKeyReader: NSViewRepresentable {
    var onKey: @MainActor (PopoverKey) -> Bool

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
                let key: PopoverKey
                switch (event.keyCode, event.modifierFlags.intersection([.command, .option, .control, .shift])) {
                case (53, _): key = .escape
                case (36, []): key = .return
                case (43, [.command]): key = .settings
                case (6, [.command]): key = .undo
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
                    if reader.onKey(key) { return true }
                    guard key == .escape else { return false }
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

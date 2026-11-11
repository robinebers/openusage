import SwiftUI
import AppKit

enum PopoverKey {
    case escape
    case `return`
    case settings
    case undo
}

extension PopoverKey {
    /// Esc and Return sit on the same key in every layout, so they match by key code. ⌘, and ⌘Z match the
    /// character typed with ⌘ held, so they follow the layout, including one like Dvorak – QWERTY ⌘ that
    /// switches to QWERTY while ⌘ is down: on QWERTZ the Z key sits where QWERTY has Y.
    init?(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers, event.characters?.lowercased()) {
        case (53, _, _): self = .escape
        case (36, [], _): self = .return
        case (_, [.command], ","): self = .settings
        case (_, [.command], "z"): self = .undo
        default: return nil
        }
    }
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
                guard let key = PopoverKey(event) else { return event }
                let eventWindow = event.window
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let reader = self.reader, let window = self.window, window.isVisible else { return false }
                    guard eventWindow === window else { return false }
                    if window.firstResponder is NSText {
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

@MainActor
enum MenuBarPopover {
    static var applyHeight: ((CGFloat) -> Void)?
    static var clampHeight: ((CGFloat) -> CGFloat)?
}

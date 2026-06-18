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

/// Handles Esc in the hosting menu-bar popover: a handler gets first refusal (e.g. backing out of
/// Customize); when it declines, the popover is dismissed through `MenuBarPopover.dismiss`, the
/// same path a status-item click takes — so it stays in sync, reopens in one click, and trips the
/// visibility reset (cancelling edit mode + the jiggle).
struct EscapeToCloseReader: NSViewRepresentable {
    /// Called first on Esc. Return `true` when the press was handled in-popover (Esc then does
    /// NOT close); return `false` to let the popover dismiss.
    var onEscape: @MainActor () -> Bool = { false }

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onEscape = onEscape
    }

    /// Whether an Esc keyDown belongs to the popover. The popover is normally the key window, so the
    /// event carries its id. But on macOS 26+ an accessory app can briefly fail to take key focus
    /// when the popover opens (the same activation race the Settings shortcut recorder re-asserts
    /// focus to dodge), and the keyDown then arrives with no key window (`eventWindowID == nil`).
    /// Treat that as the popover's too — while the Esc monitor is installed the popover is the only
    /// window in play — so Esc still closes it reliably. A *different* non-nil window (e.g. an open
    /// NSMenu that owns the keyDown) is not the popover's and is left alone.
    static func escapeTargetsPopover(eventWindowID: ObjectIdentifier?, popoverWindowID: ObjectIdentifier) -> Bool {
        guard let eventWindowID else { return true }
        return eventWindowID == popoverWindowID
    }

    final class MonitorView: NSView {
        var onEscape: (@MainActor () -> Bool)?
        private var monitor: Any?
        private static let escapeKeyCode: UInt16 = 53

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == MonitorView.escapeKeyCode else { return event }
                let eventWindowID = event.window.map(ObjectIdentifier.init)
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window else { return false }
                    // Esc must target the popover (see `escapeTargetsPopover` for the key-window race).
                    guard EscapeToCloseReader.escapeTargetsPopover(
                        eventWindowID: eventWindowID,
                        popoverWindowID: ObjectIdentifier(window)
                    ) else { return false }
                    // A text control is editing, or the Settings shortcut recorder is capturing a
                    // combo: Esc belongs to it (cancel the capture), not to popover navigation.
                    if window.firstResponder is NSText || ShortcutRecorderField.isRecordingActive {
                        return false
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

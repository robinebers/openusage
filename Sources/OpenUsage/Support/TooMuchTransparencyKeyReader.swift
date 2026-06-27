import SwiftUI
import AppKit

/// Detects the secret transparency code (↑ ↑ ↓ ↓ ← → ← → B A) while the popover panel is the key window
/// and calls `onMatched` (which toggles the "too much transparency" easter egg). A deliberate sibling of
/// `PopoverKeyReader` rather than an extra hook on it: the navigation monitor is carefully tuned and
/// shouldn't carry the egg's concerns. Like that reader it installs one local `keyDown` monitor, but it
/// **never consumes** keys — it only observes, so normal typing and navigation are untouched.
struct TooMuchTransparencyKeyReader: NSViewRepresentable {
    /// Called on a completed sequence. A second completion fires it again (re-type to toggle off).
    var onMatched: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onMatched = onMatched
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onMatched = onMatched
    }

    final class MonitorView: NSView {
        var onMatched: (@MainActor () -> Void)?
        private var monitor: Any?
        private var matcher = SecretCodeMatcher()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            matcher.reset()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // The code is bare key presses: ignore auto-repeat and any ⌘/⌃/⌥ chord (Shift is
                // allowed so a capital A/B still counts — `charactersIgnoringModifiers` normalizes case).
                guard !event.isARepeat,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                    return event
                }
                let keyCode = event.keyCode
                let characters = event.charactersIgnoringModifiers
                let eventWindowID = event.window.map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.isVisible else { return }
                    // Only while the popover owns the keystroke (its key window is the panel), and not
                    // while a text field / shortcut recorder is capturing — that input is the user's.
                    guard PopoverKeyReader.keyTargetsPopover(
                        eventWindowID: eventWindowID,
                        popoverWindowID: ObjectIdentifier(window)
                    ), !(window.firstResponder is NSText), !ShortcutRecorderField.isRecordingActive else {
                        return
                    }
                    guard let token = Self.token(keyCode: keyCode, characters: characters) else {
                        // A real key that isn't part of the code breaks the run.
                        self.matcher.reset()
                        return
                    }
                    if self.matcher.accept(token) {
                        self.onMatched?()
                    }
                }
                // Never consume — the egg observes, it doesn't steal keys.
                return event
            }
        }

        // Cleanup rides `viewDidMoveToWindow(nil)` (fired when the representable is torn down or moves
        // off-window), matching `PopoverKeyReader` — so there's no `deinit` reaching the non-Sendable
        // monitor token from a nonisolated context under Swift 6.

        /// Arrows by virtual key code (layout-stable); A/B by character. Matching A/B by `keyCode` would
        /// be wrong on non-QWERTY layouts (the ANSI "A" key code is `0`, i.e. a different physical key).
        private static func token(keyCode: UInt16, characters: String?) -> SecretCodeKey? {
            switch keyCode {
            case 126: return .up
            case 125: return .down
            case 123: return .left
            case 124: return .right
            default: break
            }
            switch characters?.lowercased() {
            case "a": return .a
            case "b": return .b
            default: return nil
            }
        }
    }
}

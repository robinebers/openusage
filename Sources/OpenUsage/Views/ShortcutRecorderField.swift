import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// A click-to-record shortcut field backed by the KeyboardShortcuts store.
///
/// This replaces `KeyboardShortcuts.Recorder`, whose NSSearchField needs to become first
/// responder of a key window to see key presses — focus plumbing that does not work inside the
/// menu-bar popover on macOS 26+ (clicking the field looked focused but recorded nothing).
/// Recording here uses a local key-event monitor instead, which only needs the app to be active,
/// so it works wherever the popover does. Storage and the global hotkey stay with the
/// KeyboardShortcuts library (`setShortcut` persists and re-registers automatically).
struct ShortcutRecorderField: View {
    let name: KeyboardShortcuts.Name

    /// Read by `EscapeToCloseReader`: while recording, Esc belongs to the recorder (cancel), not
    /// to popover navigation. The recorder's own monitor consumes the press; this flag keeps the
    /// popover's Esc handling from also acting on it.
    @MainActor static private(set) var isRecordingActive = false

    @State private var isRecording = false
    @State private var keyMonitor: Any?
    /// Re-renders the chip after `setShortcut` (the library's store isn't observable).
    @State private var currentShortcut: KeyboardShortcuts.Shortcut?
    /// The hosting popover window; key events only reach the local monitor while the app is
    /// active and some window is key, so recording starts by making this one key.
    @State private var hostWindow: NSWindow?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                chipContent
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quinary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                lineWidth: isRecording ? 1.5 : 1
                            )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isRecording, currentShortcut != nil {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .hoverTooltip("Clear Shortcut")
                .accessibilityLabel("Clear Shortcut")
            }
        }
        .onAppear {
            currentShortcut = KeyboardShortcuts.getShortcut(for: name)
        }
        .background(HostWindowReader(window: $hostWindow))
        // Covers the popover closing (or the screen switching away) mid-recording.
        .onDisappear {
            stopRecording()
        }
    }

    @ViewBuilder
    private var chipContent: some View {
        if isRecording {
            Text("Type Shortcut…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let currentShortcut {
            Text(currentShortcut.description)
                .font(.system(.callout, design: .monospaced))
        } else {
            Text("Record Shortcut")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func clear() {
        KeyboardShortcuts.setShortcut(nil, for: name)
        currentShortcut = nil
    }

    private func startRecording() {
        stopRecording()
        // Without a monitor there is no recording session — bail before touching any state, or
        // the UI would sit in "Type Shortcut…" with the hotkey disabled and nothing listening.
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            MainActor.assumeIsolated {
                handleRecorded(event)
            }
            return nil
        }) else {
            NSSound.beep()
            return
        }
        keyMonitor = monitor
        isRecording = true
        Self.isRecordingActive = true
        NSApp.activate(ignoringOtherApps: true)
        hostWindow?.makeKey()
        // The combo being recorded may be the current hotkey itself (or contain it) — don't let
        // the press toggle the popover out from under the recorder.
        KeyboardShortcuts.disable(name)
    }

    private func handleRecorded(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            stopRecording()
            return
        }
        if event.keyCode == UInt16(kVK_Delete), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            clear()
            stopRecording()
            return
        }
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event), isValid(shortcut) else {
            NSSound.beep()
            return
        }
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        currentShortcut = shortcut
        stopRecording()
    }

    /// Global hotkeys need a real modifier; plain keys (or shift-only) would hijack normal typing.
    private func isValid(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        !shortcut.modifiers.intersection([.command, .option, .control]).isEmpty
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard isRecording else { return }
        isRecording = false
        Self.isRecordingActive = false
        KeyboardShortcuts.enable(name)
    }
}

/// Reports the window hosting the view, so recording can make it key.
private struct HostWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindowChange = { window = $0 }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowReportingView)?.onWindowChange = { window = $0 }
    }

    final class WindowReportingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            // Defer past the SwiftUI update that triggered the move.
            DispatchQueue.main.async { [weak self] in
                self?.onWindowChange?(window)
            }
        }
    }
}

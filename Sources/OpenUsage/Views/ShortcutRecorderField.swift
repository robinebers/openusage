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
    var isVisible = true

    @MainActor static private(set) var isRecordingActive = false

    @State private var isRecording = false
    @State private var keyMonitor: Any?
    /// Re-renders the chip after `setShortcut` (the library's store isn't observable).
    @State private var currentShortcut: KeyboardShortcuts.Shortcut?

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
        .onChange(of: isVisible) { _, isVisible in
            if !isVisible { stopRecording() }
        }
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
        // Key events only reach the local monitor while some window is key: make the popover
        // window the chip was clicked in key.
        NSApp.currentEvent?.window?.makeKey()
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

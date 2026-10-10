import AppKit
import SwiftUI

/// AppKit only owns the early window; the welcome model and view own the flow.
@MainActor
final class FirstLaunchWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var detectionTask: Task<Void, Never>?
    private var finishing = false

    init(setup: FirstLaunchSetup, finish: @escaping (Set<String>) -> Void) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Welcome to OpenUsage"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: FirstLaunchWelcomeView(setup: setup, finish: finish))
        window.center()
        detectionTask = Task { await setup.detect() }
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func finish() {
        finishing = true
        detectionTask?.cancel()
        window.close()
        NSApp.setActivationPolicy(.accessory)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !finishing {
            detectionTask?.cancel()
            NSApp.terminate(nil)
        }
        return true
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

/// Tests host real windows in the xctest process, on a Mac whose owner is typing somewhere else. The
/// suite takes nothing from them: the process may not be activated, every hosted window is
/// transparent, sits beyond the screens and is ordered front without becoming key, and a test that
/// activates the process, makes a window key or shows one on a screen fails, however briefly it did.
///
/// The key window is what bites: xctest can't be activated and `lsappinfo front` never names it, but
/// a non-activating panel (the dashboard's `MenuBarPanel`) becomes key without activating anything,
/// and the key window is where the keystrokes go. A sheet on such a panel does the same and marks the
/// process active, and AppKit pulls a titled window, and any window a sheet attaches to, onto a
/// screen wherever its frame was. Tests that need the keyboard — a key window, an active app — skip
/// unless `OPENUSAGE_FOCUS_TESTS=1` asks for them. `script/test_quiet.sh` runs the suite and checks
/// from outside that no test process came to the front.
enum QuietTestProcess {
    static let focusTestsRequested = ProcessInfo.processInfo.environment["OPENUSAGE_FOCUS_TESTS"] == "1"

    @MainActor private static var installed = false

    /// Once per process, before the first window: the process can't be activated.
    @MainActor
    static func install() {
        guard !installed else { return }
        installed = true
        guard !focusTestsRequested else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// Skips the calling test unless the keyboard tests were asked for.
    static func requireFocus() throws {
        guard focusTestsRequested else {
            throw XCTSkip("needs the keyboard: run with OPENUSAGE_FOCUS_TESTS=1")
        }
    }

    /// Shows `window` fully transparent and beyond every screen, front but never key, and closes it
    /// when the test ends. Transparent because AppKit pulls a window onto a screen as a sheet attaches
    /// to it, wherever it was; beyond the screens so that, short of that, it never covers anything. A
    /// titled `NSWindow` is pulled back onto a screen as it shows, so it must be a `QuietWindow`.
    @MainActor
    static func show(_ window: NSWindow, in testCase: XCTestCase, file: StaticString = #filePath, line: UInt = #line) {
        let screens = NSScreen.screens.map(\.frame)
        let origin = NSPoint(x: (screens.map(\.maxX).max() ?? 0) + 1_000, y: (screens.map(\.maxY).max() ?? 0) + 1_000)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        XCTAssertFalse(screens.contains { $0.intersects(window.frame) }, "the window sits on a screen at \(window.frame)", file: file, line: line)
        XCTAssertFalse(window.isKeyWindow, "showing the window made it key", file: file, line: line)
        XCTAssertFalse(NSApp.isActive, "showing the window activated the process", file: file, line: line)
        testCase.addTeardownBlock { @MainActor in
            window.attachedSheet.map { window.endSheet($0) }
            window.close()
        }
    }

    /// Whether the owner could see the window: visible, drawn, and over a screen.
    @MainActor
    static func onAScreen(_ window: NSWindow) -> Bool {
        window.isVisible && window.alphaValue > 0 && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    /// What the owner would notice right now, or `nil`.
    @MainActor
    static func intrusion() -> String? {
        if NSApp.isActive { return "the process active" }
        if let key = NSApp.keyWindow { return "\(type(of: key)) key" }
        if let seen = NSApp.windows.first(where: onAScreen) { return "\(type(of: seen)) on a screen at \(seen.frame)" }
        return nil
    }

    @MainActor private static var sampler: Timer?
    @MainActor private static var noticed: String?

    /// Samples the process 20 times a second while a test runs, so a window key for a moment in the
    /// middle of a test fails it too, not only one left key at its end.
    @MainActor
    fileprivate static func startSampling() {
        noticed = nil
        sampler = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if noticed == nil { noticed = intrusion() }
            }
        }
    }

    /// Stops sampling and gives back what the test did to the owner, if anything, after undoing it.
    @MainActor
    fileprivate static func stopSampling() -> String? {
        sampler?.invalidate()
        sampler = nil
        let taken = intrusion().map { "left \($0)" } ?? noticed.map { "had \($0)" }
        NSApp.keyWindow?.resignKey()
        NSApp.deactivate()
        return taken
    }
}

/// A test that hosts windows: the quiet process is installed before any of its tests run, and a test
/// that activates the process, makes a window key or shows one on a screen, for however short a
/// moment, fails.
@MainActor
class QuietWindowTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        MainActor.assumeIsolated { QuietTestProcess.install() }
    }

    override func setUp() {
        super.setUp()
        if !QuietTestProcess.focusTestsRequested { QuietTestProcess.startSampling() }
    }

    override func tearDown() {
        if !QuietTestProcess.focusTestsRequested, let taken = QuietTestProcess.stopSampling() {
            XCTFail("the test \(taken), which takes the keyboard from whoever is typing")
        }
        super.tearDown()
    }
}

/// The quiet windows a test hosts a view in.
enum QuietHost {
    /// The dashboard's own panel, so clicks, hovers and the rename field behave as in the app, minus the
    /// keyboard: it never becomes key.
    case panel
    case titled
    case borderless
}

@MainActor
extension QuietWindowTestCase {
    /// Shows `content` in a hosting view sized to what it asks for (or `size`), in a quiet window of `kind`
    /// under `appearance` that takes pointer events, laid out.
    func show(
        _ content: some View,
        in kind: QuietHost = .panel,
        appearance: NSAppearance.Name = .aqua,
        size: CGSize? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (window: NSWindow, host: NSView) {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
        let window: NSWindow = switch kind {
        case .panel: QuietMenuBarPanel(contentRect: host.frame)
        case .titled: QuietWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        case .borderless: QuietWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        }
        window.acceptsMouseMovedEvents = true
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        QuietTestProcess.show(window, in: self, file: file, line: line)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    /// The host's pixels as drawn now, for an exact comparison between two states.
    func pixels(of host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

/// A window that stays where a test puts it and never takes the keyboard: AppKit pulls a titled
/// window back onto a screen as it shows, and this one sits beyond every screen; it can't become key,
/// and a sheet it presents is invisible.
final class QuietWindow: NSWindow, NSWindowDelegate {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        delegate = self
    }

    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// AppKit places the sheet, and pulls it onto a screen: it draws nothing.
    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        sheet.alphaValue = 0
        return rect
    }
}

/// The dashboard's panel as a test hosts it: it takes the events a test sends it and never the
/// keyboard, so the panel's own makeKey on a click, and the rename field's as it appears, do nothing;
/// a sheet it presents is invisible.
final class QuietMenuBarPanel: MenuBarPanel, NSWindowDelegate {
    override init(contentRect: NSRect) {
        super.init(contentRect: contentRect)
        delegate = self
    }

    override var canBecomeKey: Bool { false }

    /// AppKit places the sheet, and pulls it onto a screen: it draws nothing.
    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        sheet.alphaValue = 0
        return rect
    }
}

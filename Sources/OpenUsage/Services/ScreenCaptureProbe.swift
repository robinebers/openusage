import CoreGraphics
import Darwin
import Foundation
import os

/// Answers "is anything watching the screen right now?" — the live signal behind the menu bar's
/// Hide From Screen Share setting (`MenuBarPrivacyStore`).
///
/// The window server tracks every attached capture stream — Zoom/Meet/Teams screen shares, QuickTime
/// and `screencapture` recordings, OBS, macOS Screen Sharing — but macOS gives AppKit apps no public
/// "someone is capturing" API (SwiftUI's `isSceneCaptured` is iOS/Catalyst-only, and
/// `NSWindow.sharingType = .none` stopped hiding windows from ScreenCaptureKit on macOS 15). The one
/// reliable signal is the window server's own watcher flag, so it's resolved at runtime via `dlsym`
/// (SkyLight's `SLSIsScreenWatcherPresent`, with the older CoreGraphics `CGS` spelling as a fallback)
/// rather than linked, and its absence degrades instead of crashing: the probe logs the gap loudly once
/// and falls back to the public session dictionary, which still reports macOS Screen Sharing and remote
/// sessions (but not in-app captures).
enum ScreenCaptureProbe {
    /// `SLSIsScreenWatcherPresent()` — true while any process holds a capture stream on the screen.
    private typealias IsWatcherPresent = @convention(c) () -> Bool
    /// `SLSRegisterNotifyProc(callback, event, context)` — window-server notification registration.
    /// The callback signature is the window server's `(event, data, dataLength, context)`.
    private typealias RegisterNotifyProc = @convention(c) (
        @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32

    /// Window-server notification ids for a screen watcher attaching/detaching — the pair the system's
    /// own capture indicator rides. Private but long-stable; they only make detection *faster*, never
    /// correct (the store's poll is the guarantee), so a silent change can't break the feature.
    private static let watcherAttachedEvent: UInt32 = 1502
    private static let watcherDetachedEvent: UInt32 = 1503

    private static let isWatcherPresent: IsWatcherPresent? =
        symbol("SLSIsScreenWatcherPresent", "CGSIsScreenWatcherPresent")
            .map { unsafeBitCast($0, to: IsWatcherPresent.self) }

    private static let registerNotifyProc: RegisterNotifyProc? =
        symbol("SLSRegisterNotifyProc", "CGSRegisterNotifyProc")
            .map { unsafeBitCast($0, to: RegisterNotifyProc.self) }

    /// The installed change handler. The window server invokes the notification callback on its own
    /// thread, so the box is lock-protected rather than actor-bound.
    private static let changeHandler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    /// Registration is once per process — the window server offers no unregister.
    @MainActor private static var didInstall = false

    /// Whether any process is capturing the screen right now. One window-server call; cheap enough to
    /// poll. Falls back to the public session dictionary when the private symbol is unavailable.
    static func isScreenCaptured() -> Bool {
        if let isWatcherPresent { return isWatcherPresent() }
        return sessionReportsSharedScreen()
    }

    /// Installs `handler` to run whenever a screen watcher attaches or detaches, so the menu bar swaps
    /// the instant a share starts instead of waiting out a poll tick. Best-effort: registration failure
    /// (or the symbols vanishing in a future macOS) is logged and detection continues on the poll alone.
    @MainActor
    static func installChangeNotifications(_ handler: @escaping @Sendable () -> Void) {
        changeHandler.withLock { $0 = handler }
        guard !didInstall else { return }
        didInstall = true

        if isWatcherPresent == nil {
            AppLog.error(.menubar, "SLSIsScreenWatcherPresent unavailable; screen-share detection is limited to remote sessions")
        }
        guard let registerNotifyProc else {
            AppLog.warn(.menubar, "SLSRegisterNotifyProc unavailable; screen-share detection relies on polling")
            return
        }
        // A C-convention callback can't capture context; it reaches the handler through the static box.
        let callback: @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void = { _, _, _, _ in
            ScreenCaptureProbe.changeHandler.withLock { $0 }?()
        }
        let attached = registerNotifyProc(callback, watcherAttachedEvent, nil)
        let detached = registerNotifyProc(callback, watcherDetachedEvent, nil)
        AppLog.info(.menubar, "Screen-watcher notifications registered (attach: \(attached), detach: \(detached))")
    }

    /// The public fallback: `CGSessionCopyCurrentDictionary` reports macOS Screen Sharing / remote
    /// management sessions, but not in-app captures like a Zoom share.
    private static func sessionReportsSharedScreen() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsShared"] as? Bool ?? false
    }

    /// The first of `names` that resolves in any loaded image, or `nil` when none do. Resolves against
    /// `RTLD_DEFAULT` ("search every loaded image"; the constant isn't imported into Swift) — SkyLight
    /// is loaded by AppKit, so both spellings resolve against it.
    private static func symbol(_ names: String...) -> UnsafeMutableRawPointer? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        for name in names {
            if let address = dlsym(rtldDefault, name) { return address }
        }
        return nil
    }
}

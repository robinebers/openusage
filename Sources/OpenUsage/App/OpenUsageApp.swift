import AppKit
import SwiftUI

@main
struct OpenUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar app: the status item and popover are AppKit-owned (see StatusItemController),
        // so no window scene is wanted. `Settings` gives SwiftUI a valid scene without creating
        // an activation window.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer?
    private var statusItemController: StatusItemController?
    private let updater = UpdaterController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Open/trim the file log, seed the cached level, and emit the startup line BEFORE anything
        // else logs, so the first lines of a session are captured.
        AppLog.bootstrap()
        // Single-instance guard (#635): reject a duplicate before it grabs the local-API port
        // (127.0.0.1:6736) or adds a second status item. `terminate(_:)` unwinds asynchronously and
        // is cancellable, so we MUST return here — otherwise this method keeps running and creates
        // the very duplicate it was meant to prevent.
        if SingleInstanceGuard.deferToExistingInstance() {
            AppLog.info(.lifecycle, "duplicate launch detected; handing off to the running instance and terminating")
            NSApp.terminate(nil)
            return
        }
        // Versioned settings migration — replaces the old beta-era "wipe all settings on every update".
        // MUST run before anything reads or writes UserDefaults (AppKit below, AppearanceSetting, and the
        // AppContainer stores), so migrated values are in place when the stores load and a genuine fresh
        // install still presents an empty domain — how the migrator tells a first launch from an upgrade.
        // Nothing is wiped now; settings carry across updates. See `SettingsMigrator`.
        SettingsMigrator.migrate()
        // Let only the `SMAppService` login item drive startup: opt out of AppKit's reopen-on-login
        // so a reboot doesn't also restore us and race the login item in the first place. The guard
        // above already resolves the race deterministically (lowest PID survives) even if both fire;
        // this just avoids the wasted second launch.
        NSApp.disableRelaunchOnLogin()
        // App-wide theme override (NSApp.appearance): the popover ignores SwiftUI's
        // preferredColorScheme, so the override is applied at the AppKit level once at launch;
        // the Theme picker on the Settings screen re-applies it on change.
        AppearanceSetting.applyCurrent()
        let container = AppContainer()
        self.container = container
        statusItemController = StatusItemController(container: container, updater: updater)
        // Starts background update checks (release build only; dormant under preview/`swift run`).
        updater.start()
    }

    /// Flush queued telemetry on quit. The SDK's lifecycle autocapture is off (we emit our own daily
    /// rollups), so it won't auto-flush on termination — this explicit flush keeps low-frequency events
    /// from being stranded across a clean quit.
    func applicationWillTerminate(_ notification: Notification) {
        container?.telemetry.flush()
    }
}

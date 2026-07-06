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
    /// Widget clicks can reach the delegate before `applicationDidFinishLaunching` has assembled the
    /// AppKit-owned status item. Keep only validated-at-use URLs here, then drain them once the
    /// controller exists. This also gives warm and cold launches the same routing path.
    private var pendingOpenURLs: [URL] = []
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
        // The fresh-install answer is captured BEFORE migrating (the schema stamp makes the domain
        // non-empty) and handed to `AppContainer`, whose `FirstRunSeeder` seeds a minimal provider set.
        let isFreshInstall = SettingsMigrator.isFreshInstall()
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
        let container = AppContainer(isFreshInstall: isFreshInstall)
        self.container = container
        let statusItemController = StatusItemController(container: container, updater: updater)
        self.statusItemController = statusItemController
        for url in pendingOpenURLs {
            statusItemController.openProviderDeepLink(url)
        }
        pendingOpenURLs.removeAll()
        // Starts background update checks (release build only; dormant under preview/`swift run`).
        updater.start()
    }

    /// Handles the widget URL scheme declared by this build (`openusage://` for release or
    /// `openusage-dev://` for development). Parsing and known-provider validation live at the
    /// controller boundary; queuing raw URLs here is safe because nothing is rendered or used as an
    /// identifier until that validation.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let statusItemController else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            statusItemController.openProviderDeepLink(url)
        }
    }

    /// Flush queued telemetry on quit. The SDK's lifecycle autocapture is off (we emit our own daily
    /// rollups), so it won't auto-flush on termination — this explicit flush keeps low-frequency events
    /// from being stranded across a clean quit.
    func applicationWillTerminate(_ notification: Notification) {
        container?.telemetry.flush()
    }
}

/// The deliberately small URL surface exposed by widget cards.
///
/// Only `openusage[-dev]://provider/<known-id>` is accepted. In particular, query/fragment/user-info
/// and extra path components are rejected so untrusted URL text never becomes view identity, copy, or
/// logging input. The final allow-list check binds the route to the live provider registry.
struct ProviderDeepLink: Equatable, Sendable {
    let providerID: String

    static func parse(
        _ url: URL,
        expectedScheme: String,
        knownProviderIDs: Set<String>
    ) -> ProviderDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == expectedScheme.lowercased(),
              scheme == "openusage" || scheme == "openusage-dev",
              components.host?.lowercased() == "provider",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else { return nil }

        let pathComponents = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathComponents.count == 1 else { return nil }
        let providerID = String(pathComponents[0])
        guard knownProviderIDs.contains(providerID) else { return nil }
        return ProviderDeepLink(providerID: providerID)
    }
}

enum ProviderDeepLinkDestination: Equatable, Sendable {
    case dashboard
    case customize

    static func resolve(isEnabled: Bool, hasVisibleMetrics: Bool) -> Self {
        isEnabled && hasVisibleMetrics ? .dashboard : .customize
    }
}

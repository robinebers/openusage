import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer?
    private var statusItemController: StatusItemController?
    /// Widget clicks can reach the delegate before `applicationDidFinishLaunching` has assembled the
    /// AppKit-owned status item. Queue them until the controller can validate and route each URL.
    private var pendingOpenURLs: [URL] = []
    private var singleInstanceLock: SingleInstanceLock.Token?
    private let updater = UpdaterController()

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Open/trim the file log, seed the cached level, and emit the startup line BEFORE anything
        // else logs, so the first lines of a session are captured.
        AppLog.bootstrap()
        // Kernel-level single-instance lock (#874): rejects a duplicate even when two copies launch
        // so close together that the workspace guard's LaunchServices snapshot misses the peer.
        var holdsLock = false
        if let bundleID = Bundle.main.bundleIdentifier {
            switch SingleInstanceLock.acquire(bundleIdentifier: bundleID) {
            case .acquired(let token):
                singleInstanceLock = token
                holdsLock = true
            case .alreadyRunning:
                SingleInstanceGuard.activateExistingInstance()
                AppLog.info(.lifecycle, "duplicate launch detected by process lock; terminating")
                NSApp.terminate(nil)
                return
            case .failed(let message):
                AppLog.error(.lifecycle, "single-instance lock unavailable: \(message)")
            }
        }
        // The lock winner must NOT consult the workspace guard: its snapshot can still contain a
        // lock loser that is mid-exit (alive, lower PID), and yielding to it leaves ZERO instances
        // (reproduced in #874). The guard remains only as the fallback for unbundled launches
        // (`swift run` has no bundle ID) or lock setup failure. `terminate(_:)` unwinds
        // asynchronously and is cancellable, so we MUST return here — otherwise this method keeps
        // running and creates the very duplicate it was meant to prevent.
        if !holdsLock, SingleInstanceGuard.deferToExistingInstance() {
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
        // so a reboot doesn't also restore us and race the login item in the first place. The lock
        // above resolves same-bundle startup races even if both launch triggers fire; this just avoids
        // the wasted second launch.
        NSApp.disableRelaunchOnLogin()
        // The legacy Tauri edition's autostart agent (~/Library/LaunchAgents/OpenUsage.plist)
        // survives the upgrade and re-launches this binary at every login, racing the login item —
        // the double launch behind #874 and the "SUNSTORY LLC" Login Items entry from #607.
        // Deleting it (only when it provably points into our bundle) stops that race at the source;
        // the instance guard above stays as the referee for the remaining triggers. Runs after the
        // guard on purpose, so only the surviving copy touches the file.
        LegacyLaunchAgentCleanup.removeLeftoverAgent()
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

    /// Handles the channel-specific widget URL scheme. Parsing and known-provider validation live at
    /// the controller boundary so queued URLs are never used as view identity before validation.
    public func application(_ application: NSApplication, open urls: [URL]) {
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
    public func applicationWillTerminate(_ notification: Notification) {
        container?.telemetry.flush()
    }
}

/// The deliberately small URL surface exposed by widget cards.
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

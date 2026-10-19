import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let processStartedAt = ProcessInfo.processInfo.systemUptime
    private var container: AppContainer?
    private var statusItemController: StatusItemController?
    /// Widget clicks can arrive before startup or the welcome screen has finished. Queue them until
    /// the AppKit-owned status item can validate and route each URL.
    private var pendingOpenURLs: [URL] = []
    private var firstLaunchWindow: FirstLaunchWindowController?
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
        // non-empty) and handed to `AppContainer`, whose `FirstRunSeeder` starts with no providers on
        // until the welcome screen turns on the user's picks.
        let isFreshInstall = SettingsMigrator.isFreshInstall()
        SettingsMigrator.migrate()
        if isFreshInstall { FirstLaunchSetup.markPending() }
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

        if ShellEnvironmentSnapshotStore.launchSnapshot == nil,
           !LoginShellEnvironment.shared.capturedSuccessfully {
            Task { [weak self] in
                await Task.detached(priority: .userInitiated) {
                    _ = LoginShellEnvironment.shared.ensureCaptured()
                }.value
                await self?.finishLaunching(isFreshInstall: isFreshInstall)
            }
            return
        }
        Task { [weak self] in
            await self?.finishLaunching(isFreshInstall: isFreshInstall)
        }
    }

    private func finishLaunching(isFreshInstall: Bool) async {
        let showsWelcome = FirstLaunchSetup.isPending()
        // Nothing asks for Keychain access before the user picks providers on the welcome screen.
        if showsWelcome { KeychainAccessGuard.holdPopups() }
        // A first launch that quit before seeding still owes the empty seed, or the welcome would
        // open with every provider on.
        let container = await AppContainer(isFreshInstall: isFreshInstall || showsWelcome)
        self.container = container
        guard showsWelcome else {
            startDashboard(container)
            return
        }
        let setup = FirstLaunchSetup(
            providers: ProviderCatalog.make().map(\.provider),
            cards: container.providers,
            enablement: container.enablement,
            dataStore: container.dataStore
        )
        // The hop lets the clicked button's action return before its window is torn down.
        firstLaunchWindow = FirstLaunchWindowController(setup: setup) { [weak self] in
            Task { self?.finishWelcome(container) }
        }
        firstLaunchWindow?.show()
    }

    private func finishWelcome(_ container: AppContainer) {
        firstLaunchWindow?.finish()
        firstLaunchWindow = nil
        KeychainAccessGuard.allowPopups()
        FirstLaunchSetup.clearPending()
        // With nothing on, the empty dashboard already points to Customize.
        if container.enablement.enabledIDs?.isEmpty == true {
            container.onboarding.dismissCustomizeHint()
        }
        startDashboard(container, showsDashboard: true)
    }

    private func startDashboard(_ container: AppContainer, showsDashboard: Bool = false) {
        container.startRefreshing()
        let statusItemController = StatusItemController(container: container, updater: updater)
        self.statusItemController = statusItemController
        let launchDurationMS = Int((ProcessInfo.processInfo.systemUptime - processStartedAt) * 1_000)
        AppLog.info(.lifecycle, "launch to status item ready: \(launchDurationMS) ms")
        Self.openInitialDestination(
            pendingURLs: pendingOpenURLs,
            showsDashboard: showsDashboard,
            openDashboard: { MenuBarPopover.showHandler?() },
            openURL: statusItemController.openProviderDeepLink
        )
        pendingOpenURLs.removeAll()
        // Starts background update checks (release build only; dormant under preview/`swift run`).
        updater.start()
    }

    static func openInitialDestination(
        pendingURLs: [URL],
        showsDashboard: Bool,
        openDashboard: () -> Void,
        openURL: (URL) -> Void
    ) {
        // Show the welcome flow's default first, so a queued widget link keeps its destination.
        if showsDashboard { openDashboard() }
        for url in pendingURLs { openURL(url) }
    }

    /// Handles the channel-specific widget URL scheme. Parsing and known-provider validation live at
    /// the controller boundary so queued URLs are never used as view identity before validation.
    public func application(_ application: NSApplication, open urls: [URL]) {
        guard let statusItemController else {
            pendingOpenURLs.append(contentsOf: urls)
            firstLaunchWindow?.show()
            return
        }
        for url in urls {
            statusItemController.openProviderDeepLink(url)
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        firstLaunchWindow?.show()
        return true
    }

    /// Flush pending snapshot writes and queued telemetry on quit. The SDK's lifecycle autocapture
    /// is off (we emit our own daily rollups), so it won't auto-flush on termination — this explicit
    /// flush keeps low-frequency events from being stranded across a clean quit.
    public func applicationWillTerminate(_ notification: Notification) {
        container?.dataStore.flushPendingSnapshotWork()
        container?.telemetry.flush()
    }
}

/// The deliberately small URL surface exposed by widget cards.
enum ProviderDeepLink: Equatable, Sendable {
    case provider(String)
    case recovery

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
        guard pathComponents.count <= 1 else { return nil }
        guard let component = pathComponents.first else { return .recovery }
        let providerID = String(component)
        guard knownProviderIDs.contains(providerID) else { return .recovery }
        return .provider(providerID)
    }
}

enum ProviderDeepLinkDestination: Equatable, Sendable {
    case dashboard
    case customize

    static func resolve(isEnabled: Bool, hasVisibleMetrics: Bool) -> Self {
        isEnabled && hasVisibleMetrics ? .dashboard : .customize
    }
}

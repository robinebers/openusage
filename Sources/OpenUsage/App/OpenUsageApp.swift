import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let processStartedAt = ProcessInfo.processInfo.systemUptime
    private var container: AppContainer?
    private var statusItemController: StatusItemController?
    private var singleInstanceLock: SingleInstanceLock.Token?
    private let updater = UpdaterController()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.bootstrap()
        if let bundleID = Bundle.main.bundleIdentifier {
            switch SingleInstanceLock.acquire(bundleIdentifier: bundleID) {
            case .acquired(let token):
                singleInstanceLock = token
            case .alreadyRunning:
                // Hand focus to the copy that owns the lock. Best-effort: LaunchServices can briefly keep
                // a just-terminated copy in its snapshot, so skip corpses, and the peer may not be
                // visible yet — the lock, not this handoff, decides who survives.
                let myPID = NSRunningApplication.current.processIdentifier
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .first { $0.processIdentifier != myPID && !$0.isTerminated && kill($0.processIdentifier, 0) == 0 }?
                    .activate()
                NSApp.terminate(nil)
                return
            case .failed(let message):
                AppLog.error(.lifecycle, "single-instance lock unavailable: \(message)")
            }
        }
        NSApp.disableRelaunchOnLogin()
        AppearanceSetting.applyCurrent()
        // The one place the PostHog SDK starts and the bundle's telemetry suite is opened. The suite is
        // separate from the app's settings, so a settings change can never re-enable optional analytics
        // the user turned off or mint a new install id.
        let container = AppContainer(telemetry: PostHogTelemetrySink(), telemetryDefaults: TelemetryRecorder.suite)
        self.container = container
        container.startRefreshing()
        statusItemController = StatusItemController(container: container, updater: updater)
        let launchDurationMS = Int((ProcessInfo.processInfo.systemUptime - processStartedAt) * 1_000)
        AppLog.info(.lifecycle, "launch to status item ready: \(launchDurationMS) ms")
        // Starts background update checks (release build only; dormant under the dev build and `swift run`).
        updater.start()
    }

    /// Flush queued telemetry on quit. The SDK's lifecycle autocapture is off (the app emits its own
    /// daily rollups), so it won't auto-flush on termination.
    public func applicationWillTerminate(_ notification: Notification) {
        container?.telemetry.flush()
    }
}

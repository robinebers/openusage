import AppKit

/// Restarts the menu-bar app. Account changes only take effect at launch — the provider list is
/// built once at startup — so adding or removing an account relaunches the app to apply it.
@MainActor
enum AppControl {
    /// Launches a fresh instance, then terminates this one.
    static func restart() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        // Best-effort handoff: give the new instance a moment to launch before this one exits. Not a
        // correctness guarantee — `terminate` synchronizes UserDefaults, so persisted account changes
        // are already on disk regardless of the timing here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}

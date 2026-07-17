import Foundation

/// Instance discovery needs the login-shell home overrides to distinguish the default login from an
/// extra one. Running with a knowingly incomplete environment can persist the real default home as an
/// instance, so a timeout safely suppresses instance runtimes for this launch instead.
enum ProviderInstanceLaunchGate {
    static func discover(
        shellEnvironmentReady: Bool,
        run: () -> ProviderInstanceDiscovery.Result
    ) -> ProviderInstanceDiscovery.Result {
        guard shellEnvironmentReady else {
            var result = ProviderInstanceDiscovery.Result()
            result.basesWithUnreadableDefault = ["claude", "codex"]
            result.notes.append(
                "login-shell environment was not ready before the launch deadline → skipping provider-instance discovery"
            )
            AppLog.warn(
                .config,
                "provider-instance discovery skipped: login-shell environment did not warm before the launch deadline"
            )
            return result
        }
        return run()
    }
}

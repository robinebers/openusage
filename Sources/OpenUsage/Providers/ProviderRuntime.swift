import Foundation

/// One AI provider OpenUsage can track. A conformer reads credentials already on the machine, calls the
/// provider's API, and normalizes the result into a `ProviderSnapshot` of `MetricLine` values that the UI
/// renders. See `docs/adding-a-provider.md` for the full walkthrough.
///
/// `refresh()` returns the latest snapshot. Build its `lines` from the app's small metric vocabulary,
/// choosing the case by the shape of the value:
/// - `.progress` — a bounded meter with a `used`/`limit` and a `format` (percent, dollars, or count). Use
///   for anything with a ceiling: session/weekly quotas, credits with a cap. Add `resetsAt` when the
///   window resets at a known time.
/// - `.text` — an unbounded value rendered as-is (e.g. "$12.34 spent"). Use when there is no limit to
///   show a meter against.
/// - `.badge` — a short status pill (e.g. "Disabled", or a pay-as-you-go cap). Use for state, not a number
///   to fill a bar with.
///
/// On failure, return `ProviderSnapshot.error(provider:error:)` with a typed provider error so the error
/// surfaces loudly in the UI and telemetry can report a stable, non-PII category. Use the message-only
/// factory only when no typed error exists.
@MainActor
protocol ProviderRuntime: AnyObject {
    var provider: Provider { get }
    var widgetDescriptors: [WidgetDescriptor] { get }

    func refresh() async -> ProviderSnapshot

    /// Whether credentials for this provider already exist on this machine — a cheap, local-only probe
    /// (files, databases, keychain, saved keys, and environment variables; never the network). Used once,
    /// on a fresh install's first launch, by `FirstRunSeeder` to enable exactly the providers with local
    /// credentials. Mirror the sources `refresh()` reads and run blocking loads via `loadOffMainActor`.
    /// Return `false` only
    /// when those sources are proven absent; an unreadable/malformed local store should be logged and
    /// count conservatively as present so the enabled provider can surface its friendly refresh error.
    func hasLocalCredentials() async -> Bool
}

/// Run a blocking, `Sendable` credential load off the MainActor.
///
/// Auth stores read credentials via the `security` (keychain) and `sqlite3` CLIs, whose `ProcessRunner`
/// waits block the calling thread for up to ~5s each. Those loads run at the top of a provider's
/// `@MainActor refresh()`, so calling them inline freezes the popover and the periodic-refresh loop for
/// the whole subprocess window (Cursor issues several reads per refresh — up to ~25s). Offloading to a
/// detached task moves the wait onto a background executor; the `Sendable` result crosses back cleanly.
/// It is awaited immediately, so it reads like a normal call while no longer blocking the actor.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .utility, operation: load).value
}

/// Throwing counterpart for credential loads that reserve `nil` for proven absence and propagate an
/// unreadable or malformed local store. Keeping the error intact lets the provider surface a friendly,
/// categorized failure instead of relabeling it as "not logged in."
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility, operation: load).value
}

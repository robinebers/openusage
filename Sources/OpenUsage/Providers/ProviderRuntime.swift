import Foundation

/// One signed-in account and its provider usage endpoint.
///
/// `refresh()` returns the latest snapshot. Build its `lines` from the app's small metric vocabulary,
/// choosing the case by the shape of the value:
/// - `.progress` — a bounded meter with a `used`/`limit` and a `format` (percent, dollars, or count). Use
///   for anything with a ceiling: session/weekly quotas, credits with a cap. Add `resetsAt` when the
///   window resets at a known time.
/// - `.values` — one or more typed, unbounded numbers.
/// - `.badge` — a short status pill (e.g. "Disabled", or a pay-as-you-go cap). Use for state, not a number
///   to fill a bar with.
///
/// On failure, return `ProviderSnapshot.error(provider:error:)` with a typed provider error.
@MainActor
protocol ProviderRuntime: AnyObject {
    var provider: Provider { get }
    var widgetDescriptors: [WidgetDescriptor] { get }

    func refresh() async -> ProviderSnapshot
    /// Makes the next `refresh()` ask again for the reads it reuses for an hour; the store calls it before
    /// a forced refresh.
    func forgetHourlyReads()
}

extension ProviderRuntime {
    func forgetHourlyReads() {}
}

/// Run a blocking, `Sendable` credential load off the MainActor.
///
/// Credential vault reads block the calling thread for as long as a Keychain prompt waits for the user.
/// They run at the top of a provider's `@MainActor refresh()`,
/// so calling them inline would freeze the popover and the periodic-refresh loop. Offloading to a
/// detached task moves the wait onto a background executor; the `Sendable` result crosses back cleanly.
/// It is awaited immediately, so it reads like a normal call while no longer blocking the actor.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .utility, operation: load).value
}

/// Throwing counterpart for blocking credential reads that distinguish absence from access failure.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility, operation: load).value
}
